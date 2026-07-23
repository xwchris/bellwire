-- SPDX-License-Identifier: AGPL-3.0-only
create extension if not exists pgcrypto with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  name text,
  avatar_url text,
  created_at timestamptz not null default now()
);

create table public.devices (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  platform text not null default 'ios' check (platform = 'ios'),
  apns_token text not null unique,
  app_version text,
  last_active_at timestamptz not null default now(),
  push_enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.device_bindings (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  code_hash text not null unique check (char_length(code_hash) = 64),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.agent_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  token_hash text not null unique check (char_length(token_hash) = 64),
  scopes text[] not null,
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.projects (
  id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  slug text not null,
  icon text not null default 'bolt.horizontal',
  category text not null default 'general',
  status text not null default 'active' check (status in ('active', 'paused')),
  endpoint text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, slug)
);

create table public.event_schemas (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  event_type text not null,
  fields jsonb not null check (jsonb_typeof(fields) = 'object'),
  version integer not null check (version > 0),
  status text not null default 'active' check (status = 'active'),
  created_at timestamptz not null default now(),
  unique (project_id, event_type, version)
);

create table public.notification_surfaces (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  event_type text not null,
  type text not null default 'notification' check (type = 'notification'),
  title_template text not null check (char_length(title_template) between 1 and 240),
  body_template text not null check (char_length(body_template) between 1 and 240),
  subtitle_template text,
  sound text not null default 'default',
  group_name text not null default 'general',
  priority text not null default 'normal' check (priority in ('normal', 'high')),
  enabled boolean not null default true,
  version integer not null check (version > 0),
  created_at timestamptz not null default now(),
  unique (project_id, event_type, version)
);

create table public.ingest_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  token_hash text not null unique check (char_length(token_hash) = 64),
  scope text not null default 'event:ingest' check (scope = 'event:ingest'),
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.events (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  event_type text not null,
  idempotency_key text not null,
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  status text not null default 'accepted' check (status = 'accepted'),
  read_at timestamptz,
  unique (project_id, idempotency_key)
);

create table public.deliveries (
  id uuid primary key default extensions.gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  channel text not null default 'apns' check (channel = 'apns'),
  status text not null default 'queued' check (status in ('queued', 'accepted_by_apns', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  provider_message_id text,
  error_code text,
  error_message text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (event_id, device_id)
);

create table public.ingest_rate_limits (
  key text primary key,
  window_started_at timestamptz not null,
  request_count integer not null check (request_count >= 0)
);

create index projects_user_updated_idx on public.projects(user_id, updated_at desc);
create index devices_user_active_idx on public.devices(user_id, push_enabled, last_active_at desc);
create index event_schemas_lookup_idx on public.event_schemas(project_id, event_type, version desc);
create index surfaces_lookup_idx on public.notification_surfaces(project_id, event_type, version desc);
create index events_project_received_idx on public.events(project_id, received_at desc);
create index events_project_unread_idx on public.events(project_id, received_at desc) where read_at is null;
create index deliveries_event_idx on public.deliveries(event_id);

create or replace view public.active_event_schemas
with (security_invoker = true)
as
select distinct on (project_id, event_type) *
from public.event_schemas
where status = 'active'
order by project_id, event_type, version desc;

create or replace view public.active_notification_surfaces
with (security_invoker = true)
as
select distinct on (project_id, event_type) *
from public.notification_surfaces
where enabled = true
order by project_id, event_type, version desc;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.consume_ingest_quota(
  p_key text,
  p_limit integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
security definer set search_path = public
as $$
declare
  current_row public.ingest_rate_limits%rowtype;
  current_time timestamptz := clock_timestamp();
begin
  if p_limit < 1 or p_window_seconds < 1 then
    return false;
  end if;

  insert into public.ingest_rate_limits(key, window_started_at, request_count)
  values (p_key, current_time, 1)
  on conflict (key) do nothing;

  select * into current_row
  from public.ingest_rate_limits
  where key = p_key
  for update;

  if current_row.window_started_at + make_interval(secs => p_window_seconds) <= current_time then
    update public.ingest_rate_limits
    set window_started_at = current_time, request_count = 1
    where key = p_key;
    return true;
  end if;

  if current_row.request_count >= p_limit then
    return false;
  end if;

  update public.ingest_rate_limits
  set request_count = request_count + 1
  where key = p_key;
  return true;
end;
$$;

revoke all on function public.consume_ingest_quota(text, integer, integer) from public, anon, authenticated;
grant execute on function public.consume_ingest_quota(text, integer, integer) to service_role;

alter table public.profiles enable row level security;
alter table public.devices enable row level security;
alter table public.device_bindings enable row level security;
alter table public.agent_tokens enable row level security;
alter table public.projects enable row level security;
alter table public.event_schemas enable row level security;
alter table public.notification_surfaces enable row level security;
alter table public.ingest_tokens enable row level security;
alter table public.events enable row level security;
alter table public.deliveries enable row level security;
alter table public.ingest_rate_limits enable row level security;

create policy "profiles_select_own" on public.profiles for select to authenticated
using (id = auth.uid());
create policy "profiles_update_own" on public.profiles for update to authenticated
using (id = auth.uid()) with check (id = auth.uid());

create policy "devices_own" on public.devices for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "device_bindings_own" on public.device_bindings for select to authenticated
using (user_id = auth.uid());

create policy "projects_own" on public.projects for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "event_schemas_read_own" on public.event_schemas for select to authenticated
using (exists (
  select 1 from public.projects
  where projects.id = event_schemas.project_id and projects.user_id = auth.uid()
));

create policy "surfaces_read_own" on public.notification_surfaces for select to authenticated
using (exists (
  select 1 from public.projects
  where projects.id = notification_surfaces.project_id and projects.user_id = auth.uid()
));

create policy "events_own" on public.events for select to authenticated
using (exists (
  select 1 from public.projects
  where projects.id = events.project_id and projects.user_id = auth.uid()
));
create policy "events_update_own" on public.events for update to authenticated
using (exists (
  select 1 from public.projects
  where projects.id = events.project_id and projects.user_id = auth.uid()
));

create policy "deliveries_read_own" on public.deliveries for select to authenticated
using (exists (
  select 1
  from public.events
  join public.projects on projects.id = events.project_id
  where events.id = deliveries.event_id and projects.user_id = auth.uid()
));

grant select on public.active_event_schemas to authenticated, service_role;
grant select on public.active_notification_surfaces to authenticated, service_role;
