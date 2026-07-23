-- SPDX-License-Identifier: AGPL-3.0-only
create table public.device_keys (
  id text primary key check (id ~ '^[0-9a-f-]{36}$'),
  user_id uuid not null references public.profiles(id) on delete cascade,
  installation_id uuid not null,
  agreement_public_key text not null check (char_length(agreement_public_key) between 80 and 100),
  signing_public_key text not null check (char_length(signing_public_key) between 80 and 100),
  algorithm text not null default 'p256' check (algorithm = 'p256'),
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (user_id, installation_id),
  unique (user_id, id)
);

alter table public.device_bindings
  add column device_key_id text;

create table public.direct_connection_envelopes (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_key_id text not null,
  algorithm text not null check (algorithm = 'p256-hkdf-sha256-aes-gcm'),
  ephemeral_public_key text not null check (char_length(ephemeral_public_key) between 80 and 100),
  sealed_box text not null check (char_length(sealed_box) between 24 and 90000),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  foreign key (user_id, device_key_id)
    references public.device_keys(user_id, id)
    on delete cascade
);

create index direct_connection_envelopes_pending_idx
  on public.direct_connection_envelopes(user_id, device_key_id, expires_at, created_at);

alter table public.device_keys enable row level security;
alter table public.direct_connection_envelopes enable row level security;

create policy "device_keys_select_own" on public.device_keys
for select to authenticated
using (user_id = auth.uid());

create policy "direct_connection_envelopes_own" on public.direct_connection_envelopes
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

comment on table public.device_keys is
  'Public device keys used for encrypted Bellwire Direct bootstrap and request verification.';
comment on table public.direct_connection_envelopes is
  'Short-lived encrypted connection manifests. Bellwire cannot decrypt their contents.';
