-- SPDX-License-Identifier: AGPL-3.0-only
create table public.apple_auth_tokens (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  refresh_token_ciphertext text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.apple_auth_tokens enable row level security;

revoke all on table public.apple_auth_tokens from public, anon, authenticated;
grant select, insert, update, delete on table public.apple_auth_tokens to service_role;
