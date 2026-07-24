-- SPDX-License-Identifier: AGPL-3.0-only
-- Bellwire Private-first delivery, authoritative entitlements, and atomic Signal metering.

alter table public.projects
  add column delivery_mode text not null default 'private'
  check (delivery_mode in ('private', 'hosted'));

-- Existing projects used the hosted data path before delivery modes existed.
update public.projects set delivery_mode = 'hosted';

drop table if exists public.notification_preferences;

-- Direct v1 envelopes cannot be safely interpreted as v2.
delete from public.direct_connection_envelopes;
alter table public.direct_connection_envelopes
  add column project_id uuid not null references public.projects(id) on delete cascade,
  add column manifest_version integer not null default 2 check (manifest_version = 2);

create index direct_connection_envelopes_project_idx
  on public.direct_connection_envelopes(project_id, device_key_id, expires_at);

create table public.private_connection_readiness (
  project_id uuid not null references public.projects(id) on delete cascade,
  device_key_id text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  manifest_version integer not null check (manifest_version = 2),
  ready_at timestamptz not null,
  last_verified_at timestamptz not null,
  last_sync_at timestamptz,
  last_error_code text,
  primary key (project_id, device_key_id),
  foreign key (user_id, device_key_id)
    references public.device_keys(user_id, id) on delete cascade
);

create table public.delivery_mode_change_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  requested_by_token_id uuid not null references public.agent_tokens(id) on delete cascade,
  from_mode text not null check (from_mode in ('private', 'hosted')),
  to_mode text not null check (to_mode in ('private', 'hosted') and to_mode <> from_mode),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  resolved_at timestamptz
);

create unique index delivery_mode_change_requests_one_pending
  on public.delivery_mode_change_requests(project_id)
  where status = 'pending';

create table public.private_wake_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  token_hash text not null unique check (char_length(token_hash) = 64),
  scope text not null default 'wake:send' check (scope = 'wake:send'),
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.private_wakes (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  idempotency_key_hash text not null check (char_length(idempotency_key_hash) = 64),
  reference text check (
    reference is null or (
      char_length(reference) between 22 and 200
      and reference ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  priority text not null default 'normal' check (priority in ('normal', 'high')),
  received_at timestamptz not null default now(),
  reference_expires_at timestamptz not null,
  unique (project_id, idempotency_key_hash)
);

create table public.private_wake_deliveries (
  id uuid primary key default extensions.gen_random_uuid(),
  wake_id uuid not null references public.private_wakes(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  channel text not null default 'apns' check (channel = 'apns'),
  status text not null default 'queued'
    check (status in ('queued', 'accepted_by_apns', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  provider_message_id text,
  error_code text,
  error_message text,
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (wake_id, device_id)
);

create index private_wakes_project_received_idx
  on public.private_wakes(project_id, received_at desc);
create index private_wake_deliveries_wake_idx
  on public.private_wake_deliveries(wake_id);

-- Persist hashes only. Historical raw keys are replaced before the raw column is removed.
alter table public.events add column idempotency_key_hash text;
update public.events
set idempotency_key_hash = encode(
  extensions.digest(convert_to(idempotency_key, 'UTF8'), 'sha256'),
  'hex'
);
alter table public.events
  alter column idempotency_key_hash set not null;
alter table public.events
  drop constraint if exists events_project_idempotency_key_key;
alter table public.events
  drop column idempotency_key;
alter table public.events
  add constraint events_project_idempotency_hash_unique
  unique (project_id, idempotency_key_hash);

create table public.billing_entitlements (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  plan text not null check (plan in ('free', 'pro')),
  status text not null check (status in ('active', 'grace', 'expired', 'revoked')),
  product_id text check (
    product_id is null or product_id in (
      'app.bellwire.pro.monthly',
      'app.bellwire.pro.yearly'
    )
  ),
  original_transaction_id text unique,
  expires_at timestamptz,
  downgrade_deadline timestamptz,
  updated_at timestamptz not null default now()
);

create table public.apple_transactions (
  transaction_id text primary key,
  original_transaction_id text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  product_id text not null check (
    product_id in ('app.bellwire.pro.monthly', 'app.bellwire.pro.yearly')
  ),
  environment text not null check (environment in ('Sandbox', 'Production')),
  purchase_date timestamptz not null,
  expires_at timestamptz,
  revocation_date timestamptz,
  status text not null check (status in ('active', 'grace', 'expired', 'revoked')),
  signed_date timestamptz not null,
  updated_at timestamptz not null default now()
);

create index apple_transactions_original_idx
  on public.apple_transactions(original_transaction_id, signed_date desc);

create table public.apple_notification_receipts (
  notification_uuid uuid primary key,
  notification_type text not null,
  subtype text,
  signed_date timestamptz not null,
  processed_at timestamptz not null default now()
);

create table public.monthly_signal_usage (
  user_id uuid not null references public.profiles(id) on delete cascade,
  month_start date not null,
  accepted_signals bigint not null default 0 check (accepted_signals >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, month_start),
  check (month_start = date_trunc('month', month_start)::date)
);

create or replace function public.resolve_account_plan(p_user_id uuid, p_now timestamptz)
returns text
language sql
stable
security definer set search_path = public
as $$
  select case
    when entitlement.plan = 'pro'
      and entitlement.status in ('active', 'grace')
      and (entitlement.expires_at is null or entitlement.expires_at > p_now)
    then 'pro'
    else 'free'
  end
  from (select 1) seed
  left join public.billing_entitlements entitlement
    on entitlement.user_id = p_user_id;
$$;

create or replace function public.account_entitlement_snapshot(
  p_user_id uuid,
  p_now timestamptz default clock_timestamp()
)
returns table (
  plan text,
  status text,
  product_id text,
  expires_at timestamptz,
  downgrade_deadline timestamptz,
  active_projects integer,
  active_devices integer,
  month_start date,
  month_end timestamptz,
  accepted_signals bigint,
  active_project_limit integer,
  active_device_limit integer,
  monthly_signal_limit integer,
  courtesy_signal_limit integer,
  ingest_per_minute integer,
  hosted_retention_days integer,
  surfaces_per_project integer
)
language plpgsql
stable
security definer set search_path = public
as $$
declare
  resolved_plan text := public.resolve_account_plan(p_user_id, p_now);
  resolved_month date := date_trunc('month', p_now at time zone 'UTC')::date;
begin
  return query
  select
    resolved_plan,
    coalesce(e.status, 'active'),
    e.product_id,
    e.expires_at,
    e.downgrade_deadline,
    (select count(*)::integer from public.projects p
      where p.user_id = p_user_id and p.status = 'active'),
    (select count(*)::integer from public.devices d
      where d.user_id = p_user_id and d.push_enabled),
    resolved_month,
    (resolved_month + interval '1 month')::timestamptz,
    coalesce(u.accepted_signals, 0),
    case when resolved_plan = 'pro' then 20 else 3 end,
    case when resolved_plan = 'pro' then 3 else 1 end,
    case when resolved_plan = 'pro' then 50000 else 5000 end,
    case when resolved_plan = 'pro' then 55000 else 5500 end,
    case when resolved_plan = 'pro' then 300 else 60 end,
    case when resolved_plan = 'pro' then 90 else 7 end,
    case when resolved_plan = 'pro' then 10 else 1 end
  from (select 1) seed
  left join public.billing_entitlements e on e.user_id = p_user_id
  left join public.monthly_signal_usage u
    on u.user_id = p_user_id and u.month_start = resolved_month;
end;
$$;

create or replace function public.accept_hosted_event_signal(
  p_id uuid,
  p_project_id uuid,
  p_event_type text,
  p_idempotency_key_hash text,
  p_data jsonb,
  p_sensitive_fields text[],
  p_occurred_at timestamptz,
  p_received_at timestamptz,
  p_enforcement_mode text
)
returns table (
  event_row jsonb,
  created boolean,
  quota_exceeded boolean,
  plan text,
  accepted_signals bigint,
  signal_limit integer,
  courtesy_limit integer,
  reset_at timestamptz
)
language plpgsql
security definer set search_path = public
as $$
declare
  owner_id uuid;
  project_mode text;
  period_start date := date_trunc('month', p_received_at at time zone 'UTC')::date;
  current_usage bigint;
  resolved_plan text;
  resolved_limit integer;
  resolved_courtesy integer;
  saved public.events%rowtype;
begin
  select user_id, delivery_mode into owner_id, project_mode
  from public.projects where id = p_project_id and status = 'active' for update;
  if not found then return; end if;
  if project_mode <> 'hosted' then
    raise exception 'PROJECT_PRIVATE_MODE' using errcode = 'P0001';
  end if;

  select * into saved from public.events
  where project_id = p_project_id
    and idempotency_key_hash = p_idempotency_key_hash;
  if found then
    resolved_plan := public.resolve_account_plan(owner_id, p_received_at);
    select coalesce(usage.accepted_signals, 0) into current_usage
    from (select 1) seed
    left join public.monthly_signal_usage usage
      on usage.user_id = owner_id and usage.month_start = period_start;
    resolved_limit := case when resolved_plan = 'pro' then 50000 else 5000 end;
    resolved_courtesy := case when resolved_plan = 'pro' then 55000 else 5500 end;
    return query select to_jsonb(saved), false, false, resolved_plan, current_usage,
      resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
    return;
  end if;

  insert into public.monthly_signal_usage(user_id, month_start)
  values (owner_id, period_start) on conflict do nothing;
  select usage.accepted_signals into current_usage
  from public.monthly_signal_usage usage
  where usage.user_id = owner_id and usage.month_start = period_start
  for update;

  resolved_plan := public.resolve_account_plan(owner_id, p_received_at);
  resolved_limit := case when resolved_plan = 'pro' then 50000 else 5000 end;
  resolved_courtesy := case when resolved_plan = 'pro' then 55000 else 5500 end;
  if p_enforcement_mode = 'enforce' and current_usage >= resolved_courtesy then
    return query select null::jsonb, false, true, resolved_plan, current_usage,
      resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
    return;
  end if;

  insert into public.events(
    id, project_id, event_type, idempotency_key_hash, data, sensitive_fields,
    occurred_at, received_at, status
  ) values (
    p_id, p_project_id, p_event_type, p_idempotency_key_hash, p_data,
    p_sensitive_fields, p_occurred_at, p_received_at, 'accepted'
  ) returning * into saved;

  update public.monthly_signal_usage
  set accepted_signals = accepted_signals + 1, updated_at = p_received_at
  where user_id = owner_id and month_start = period_start
  returning monthly_signal_usage.accepted_signals into current_usage;

  return query select to_jsonb(saved), true, false, resolved_plan, current_usage,
    resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
end;
$$;

create or replace function public.accept_private_wake_signal(
  p_id uuid,
  p_project_id uuid,
  p_idempotency_key_hash text,
  p_reference text,
  p_priority text,
  p_received_at timestamptz,
  p_reference_expires_at timestamptz,
  p_enforcement_mode text
)
returns table (
  wake_row jsonb,
  created boolean,
  quota_exceeded boolean,
  plan text,
  accepted_signals bigint,
  signal_limit integer,
  courtesy_limit integer,
  reset_at timestamptz
)
language plpgsql
security definer set search_path = public
as $$
declare
  owner_id uuid;
  project_mode text;
  period_start date := date_trunc('month', p_received_at at time zone 'UTC')::date;
  current_usage bigint;
  resolved_plan text;
  resolved_limit integer;
  resolved_courtesy integer;
  saved public.private_wakes%rowtype;
begin
  select user_id, delivery_mode into owner_id, project_mode
  from public.projects where id = p_project_id and status = 'active' for update;
  if not found then return; end if;
  if project_mode <> 'private' then
    raise exception 'PROJECT_HOSTED_MODE' using errcode = 'P0001';
  end if;

  select * into saved from public.private_wakes
  where project_id = p_project_id
    and idempotency_key_hash = p_idempotency_key_hash;
  if found then
    resolved_plan := public.resolve_account_plan(owner_id, p_received_at);
    select coalesce(usage.accepted_signals, 0) into current_usage
    from (select 1) seed
    left join public.monthly_signal_usage usage
      on usage.user_id = owner_id and usage.month_start = period_start;
    resolved_limit := case when resolved_plan = 'pro' then 50000 else 5000 end;
    resolved_courtesy := case when resolved_plan = 'pro' then 55000 else 5500 end;
    return query select to_jsonb(saved), false, false, resolved_plan, current_usage,
      resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
    return;
  end if;

  insert into public.monthly_signal_usage(user_id, month_start)
  values (owner_id, period_start) on conflict do nothing;
  select usage.accepted_signals into current_usage
  from public.monthly_signal_usage usage
  where usage.user_id = owner_id and usage.month_start = period_start for update;

  resolved_plan := public.resolve_account_plan(owner_id, p_received_at);
  resolved_limit := case when resolved_plan = 'pro' then 50000 else 5000 end;
  resolved_courtesy := case when resolved_plan = 'pro' then 55000 else 5500 end;
  if p_enforcement_mode = 'enforce' and current_usage >= resolved_courtesy then
    return query select null::jsonb, false, true, resolved_plan, current_usage,
      resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
    return;
  end if;

  insert into public.private_wakes(
    id, project_id, idempotency_key_hash, reference, priority,
    received_at, reference_expires_at
  ) values (
    p_id, p_project_id, p_idempotency_key_hash, p_reference, p_priority,
    p_received_at, p_reference_expires_at
  ) returning * into saved;

  update public.monthly_signal_usage
  set accepted_signals = accepted_signals + 1, updated_at = p_received_at
  where user_id = owner_id and month_start = period_start
  returning monthly_signal_usage.accepted_signals into current_usage;

  return query select to_jsonb(saved), true, false, resolved_plan, current_usage,
    resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
end;
$$;

create or replace function public.accept_hosted_surface_signal(
  p_id uuid,
  p_project_id uuid,
  p_surface_key text,
  p_type text,
  p_title text,
  p_subtitle text,
  p_content jsonb,
  p_action jsonb,
  p_display_order integer,
  p_created_at timestamptz,
  p_updated_at timestamptz,
  p_enforcement_mode text
)
returns table (
  surface_row jsonb,
  created boolean,
  quota_exceeded boolean,
  surface_limit_exceeded boolean,
  plan text,
  accepted_signals bigint,
  signal_limit integer,
  courtesy_limit integer,
  reset_at timestamptz
)
language plpgsql
security definer set search_path = public
as $$
declare
  owner_id uuid;
  project_mode text;
  period_start date := date_trunc('month', p_updated_at at time zone 'UTC')::date;
  current_usage bigint;
  current_surface_count integer;
  resolved_plan text;
  resolved_limit integer;
  resolved_courtesy integer;
  resolved_surface_limit integer;
  saved public.live_surfaces%rowtype;
  surface_exists boolean := false;
begin
  select user_id, delivery_mode into owner_id, project_mode
  from public.projects where id = p_project_id and status = 'active' for update;
  if not found then return; end if;
  if project_mode <> 'hosted' then
    raise exception 'PROJECT_PRIVATE_MODE' using errcode = 'P0001';
  end if;

  select * into saved from public.live_surfaces
  where project_id = p_project_id and surface_key = p_surface_key;
  surface_exists := found;

  resolved_plan := public.resolve_account_plan(owner_id, p_updated_at);
  resolved_limit := case when resolved_plan = 'pro' then 50000 else 5000 end;
  resolved_courtesy := case when resolved_plan = 'pro' then 55000 else 5500 end;
  resolved_surface_limit := case when resolved_plan = 'pro' then 10 else 1 end;
  select coalesce(usage.accepted_signals, 0) into current_usage
  from (select 1) seed
  left join public.monthly_signal_usage usage
    on usage.user_id = owner_id and usage.month_start = period_start;

  if surface_exists and saved.type = p_type
    and saved.title = p_title
    and saved.subtitle is not distinct from p_subtitle
    and saved.content = p_content
    and saved.action is not distinct from p_action
  then
    return query select to_jsonb(saved), false, false, false, resolved_plan, current_usage,
      resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
    return;
  end if;

  if not surface_exists then
    select count(*)::integer into current_surface_count
    from public.live_surfaces where project_id = p_project_id;
    if p_enforcement_mode = 'enforce' and current_surface_count >= resolved_surface_limit then
      return query select null::jsonb, false, false, true, resolved_plan, current_usage,
        resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
      return;
    end if;
  end if;

  insert into public.monthly_signal_usage(user_id, month_start)
  values (owner_id, period_start) on conflict do nothing;
  select usage.accepted_signals into current_usage
  from public.monthly_signal_usage usage
  where usage.user_id = owner_id and usage.month_start = period_start for update;

  if p_enforcement_mode = 'enforce' and current_usage >= resolved_courtesy then
    return query select null::jsonb, false, true, false, resolved_plan, current_usage,
      resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
    return;
  end if;

  if surface_exists then
    update public.live_surfaces
    set type = p_type,
        title = p_title,
        subtitle = p_subtitle,
        content = p_content,
        action = p_action,
        version = version + 1,
        updated_at = p_updated_at
    where id = saved.id
    returning * into saved;
  else
    insert into public.live_surfaces(
      id, project_id, surface_key, type, title, subtitle, content, action,
      display_order, version, created_at, updated_at
    ) values (
      p_id, p_project_id, p_surface_key, p_type, p_title, p_subtitle, p_content,
      p_action, p_display_order, 1, p_created_at, p_updated_at
    ) returning * into saved;
  end if;

  update public.monthly_signal_usage
  set accepted_signals = accepted_signals + 1, updated_at = p_updated_at
  where user_id = owner_id and month_start = period_start
  returning monthly_signal_usage.accepted_signals into current_usage;

  return query select to_jsonb(saved), true, false, false, resolved_plan, current_usage,
    resolved_limit, resolved_courtesy, (period_start + interval '1 month')::timestamptz;
end;
$$;

create or replace function public.ack_direct_connection_envelope(
  p_envelope_id uuid,
  p_user_id uuid,
  p_device_key_id text,
  p_verified_at timestamptz
)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  envelope public.direct_connection_envelopes%rowtype;
begin
  select * into envelope from public.direct_connection_envelopes
  where id = p_envelope_id
    and user_id = p_user_id
    and device_key_id = p_device_key_id
    and expires_at > p_verified_at
  for update;
  if not found then return null; end if;

  insert into public.private_connection_readiness(
    project_id, device_key_id, user_id, manifest_version, ready_at, last_verified_at
  ) values (
    envelope.project_id, envelope.device_key_id, envelope.user_id,
    envelope.manifest_version, p_verified_at, p_verified_at
  )
  on conflict (project_id, device_key_id) do update
  set manifest_version = excluded.manifest_version,
      last_verified_at = excluded.last_verified_at,
      last_error_code = null;

  delete from public.direct_connection_envelopes where id = envelope.id;
  return envelope.project_id;
end;
$$;

create or replace function public.resolve_delivery_mode_request(
  p_request_id uuid,
  p_user_id uuid,
  p_approved boolean,
  p_resolved_at timestamptz
)
returns setof public.delivery_mode_change_requests
language plpgsql
security definer set search_path = public
as $$
declare
  request_row public.delivery_mode_change_requests%rowtype;
begin
  select * into request_row from public.delivery_mode_change_requests
  where id = p_request_id and user_id = p_user_id and status = 'pending'
  for update;
  if not found then return; end if;

  if request_row.expires_at <= p_resolved_at then
    update public.delivery_mode_change_requests
    set status = 'expired', resolved_at = p_resolved_at
    where id = p_request_id returning * into request_row;
    return next request_row;
    return;
  end if;

  if p_approved then
    if request_row.to_mode = 'private' and not exists (
      select 1 from public.private_connection_readiness readiness
      join public.device_keys device_key
        on device_key.user_id = readiness.user_id
        and device_key.id = readiness.device_key_id
        and device_key.revoked_at is null
      join public.devices device
        on device.user_id = readiness.user_id
        and device.installation_id = device_key.installation_id
        and device.push_enabled
      where readiness.project_id = request_row.project_id
    ) then
      raise exception 'PRIVATE_READINESS_REQUIRED' using errcode = 'P0001';
    end if;
    update public.projects set delivery_mode = request_row.to_mode, updated_at = p_resolved_at
    where id = request_row.project_id;
    if request_row.to_mode = 'private' then
      update public.ingest_tokens set revoked_at = p_resolved_at
      where project_id = request_row.project_id and revoked_at is null;
    else
      update public.private_wake_tokens set revoked_at = p_resolved_at
      where project_id = request_row.project_id and revoked_at is null;
    end if;
  end if;

  update public.delivery_mode_change_requests
  set status = case when p_approved then 'approved' else 'rejected' end,
      resolved_at = p_resolved_at
  where id = p_request_id returning * into request_row;
  return next request_row;
end;
$$;

create or replace function public.record_verified_apple_transaction(
  p_transaction_id text,
  p_original_transaction_id text,
  p_user_id uuid,
  p_product_id text,
  p_environment text,
  p_purchase_date timestamptz,
  p_expires_at timestamptz,
  p_revocation_date timestamptz,
  p_status text,
  p_signed_date timestamptz,
  p_updated_at timestamptz
)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  latest_signed_date timestamptz;
begin
  insert into public.apple_transactions(
    transaction_id, original_transaction_id, user_id, product_id, environment,
    purchase_date, expires_at, revocation_date, status, signed_date, updated_at
  ) values (
    p_transaction_id, p_original_transaction_id, p_user_id, p_product_id, p_environment,
    p_purchase_date, p_expires_at, p_revocation_date, p_status, p_signed_date, p_updated_at
  )
  on conflict (transaction_id) do update
  set expires_at = excluded.expires_at,
      revocation_date = excluded.revocation_date,
      status = excluded.status,
      signed_date = excluded.signed_date,
      updated_at = excluded.updated_at
  where excluded.signed_date >= apple_transactions.signed_date;

  select max(signed_date) into latest_signed_date
  from public.apple_transactions
  where user_id = p_user_id
    and original_transaction_id = p_original_transaction_id;

  if latest_signed_date = p_signed_date then
    insert into public.billing_entitlements(
      user_id, plan, status, product_id, original_transaction_id,
      expires_at, downgrade_deadline, updated_at
    ) values (
      p_user_id,
      case when p_status in ('active', 'grace') then 'pro' else 'free' end,
      p_status,
      p_product_id,
      p_original_transaction_id,
      p_expires_at,
      case when p_status in ('expired', 'revoked')
        then p_updated_at + interval '7 days' else null end,
      p_updated_at
    )
    on conflict (user_id) do update
    set plan = excluded.plan,
        status = excluded.status,
        product_id = excluded.product_id,
        original_transaction_id = excluded.original_transaction_id,
        expires_at = excluded.expires_at,
        downgrade_deadline = excluded.downgrade_deadline,
        updated_at = excluded.updated_at;
  end if;
end;
$$;

create or replace function public.cleanup_bellwire_retention(
  p_now timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  envelope_count bigint;
  wake_reference_count bigint;
  private_count bigint;
  hosted_event_count bigint;
  expired_mode_request_count bigint;
  paused_project_count bigint;
  disabled_device_count bigint;
begin
  update public.delivery_mode_change_requests
  set status = 'expired', resolved_at = p_now
  where status = 'pending' and expires_at <= p_now;
  get diagnostics expired_mode_request_count = row_count;

  delete from public.direct_connection_envelopes where expires_at <= p_now;
  get diagnostics envelope_count = row_count;

  update public.private_wakes set reference = null
  where reference is not null and reference_expires_at <= p_now;
  get diagnostics wake_reference_count = row_count;

  delete from public.private_wakes where received_at < p_now - interval '7 days';
  get diagnostics private_count = row_count;

  delete from public.events event_row
  using public.projects project_row
  left join public.billing_entitlements entitlement
    on entitlement.user_id = project_row.user_id
  where event_row.project_id = project_row.id
    and event_row.received_at < p_now - make_interval(days =>
      case when entitlement.plan = 'pro'
        and entitlement.status in ('active', 'grace')
        and (entitlement.expires_at is null or entitlement.expires_at > p_now)
      then 90 else 7 end
    );
  get diagnostics hosted_event_count = row_count;

  delete from public.ingest_rate_limits
  where window_started_at < p_now - interval '1 day';

  with ranked_projects as (
    select project.id,
      row_number() over (
        partition by project.user_id
        order by project.updated_at desc, project.id
      ) as position
    from public.projects project
    join public.billing_entitlements entitlement
      on entitlement.user_id = project.user_id
    where project.status = 'active'
      and entitlement.plan = 'free'
      and entitlement.status in ('expired', 'revoked')
      and entitlement.downgrade_deadline <= p_now
  )
  update public.projects project
  set status = 'paused', updated_at = p_now
  from ranked_projects
  where project.id = ranked_projects.id and ranked_projects.position > 3;
  get diagnostics paused_project_count = row_count;

  with ranked_devices as (
    select device.id,
      row_number() over (
        partition by device.user_id
        order by device.last_active_at desc, device.id
      ) as position
    from public.devices device
    join public.billing_entitlements entitlement
      on entitlement.user_id = device.user_id
    where device.push_enabled
      and entitlement.plan = 'free'
      and entitlement.status in ('expired', 'revoked')
      and entitlement.downgrade_deadline <= p_now
  )
  update public.devices device
  set push_enabled = false
  from ranked_devices
  where device.id = ranked_devices.id and ranked_devices.position > 1;
  get diagnostics disabled_device_count = row_count;

  return jsonb_build_object(
    'expiredModeRequests', expired_mode_request_count,
    'envelopes', envelope_count,
    'wakeReferences', wake_reference_count,
    'privateWakes', private_count,
    'hostedEvents', hosted_event_count,
    'pausedProjects', paused_project_count,
    'disabledDevices', disabled_device_count
  );
end;
$$;

create or replace function public.claim_private_wake_delivery(
  p_delivery_id uuid,
  p_claimed_at timestamptz,
  p_lease_seconds integer,
  p_max_attempts integer
)
returns setof public.private_wake_deliveries
language plpgsql
security definer set search_path = public
as $$
declare
  claimed_delivery public.private_wake_deliveries%rowtype;
  lease_expired_before timestamptz;
begin
  if p_lease_seconds < 1 or p_max_attempts < 1 then
    return;
  end if;

  lease_expired_before := p_claimed_at - make_interval(secs => p_lease_seconds);

  update public.private_wake_deliveries
  set
    status = 'failed',
    error_code = 'permanent:LeaseExpired',
    error_message = 'Private wake worker lease expired after the maximum number of attempts',
    updated_at = p_claimed_at
  where id = p_delivery_id
    and status = 'queued'
    and attempt_count >= p_max_attempts
    and updated_at <= lease_expired_before;

  update public.private_wake_deliveries
  set
    status = 'queued',
    attempt_count = attempt_count + 1,
    error_code = null,
    error_message = null,
    updated_at = p_claimed_at
  where id = p_delivery_id
    and attempt_count < p_max_attempts
    and (
      (
        status = 'queued'
        and (attempt_count = 0 or updated_at <= lease_expired_before)
      )
      or (
        status = 'failed'
        and error_code like 'retryable:%'
      )
    )
  returning * into claimed_delivery;

  if found then
    return next claimed_delivery;
  end if;
end;
$$;

alter table public.private_connection_readiness enable row level security;
alter table public.delivery_mode_change_requests enable row level security;
alter table public.private_wake_tokens enable row level security;
alter table public.private_wakes enable row level security;
alter table public.private_wake_deliveries enable row level security;
alter table public.billing_entitlements enable row level security;
alter table public.apple_transactions enable row level security;
alter table public.apple_notification_receipts enable row level security;
alter table public.monthly_signal_usage enable row level security;

create policy "private_readiness_own" on public.private_connection_readiness
for select to authenticated using (user_id = auth.uid());
create policy "delivery_mode_requests_own" on public.delivery_mode_change_requests
for select to authenticated using (user_id = auth.uid());
create policy "billing_entitlements_own" on public.billing_entitlements
for select to authenticated using (user_id = auth.uid());
create policy "monthly_signal_usage_own" on public.monthly_signal_usage
for select to authenticated using (user_id = auth.uid());

revoke all on function public.resolve_account_plan(uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function public.account_entitlement_snapshot(uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function public.accept_hosted_event_signal(
  uuid, uuid, text, text, jsonb, text[], timestamptz, timestamptz, text
) from public, anon, authenticated;
revoke all on function public.accept_private_wake_signal(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text
) from public, anon, authenticated;
revoke all on function public.accept_hosted_surface_signal(
  uuid, uuid, text, text, text, text, jsonb, jsonb, integer,
  timestamptz, timestamptz, text
) from public, anon, authenticated;
revoke all on function public.ack_direct_connection_envelope(
  uuid, uuid, text, timestamptz
) from public, anon, authenticated;
revoke all on function public.resolve_delivery_mode_request(
  uuid, uuid, boolean, timestamptz
) from public, anon, authenticated;
revoke all on function public.record_verified_apple_transaction(
  text, text, uuid, text, text, timestamptz, timestamptz, timestamptz,
  text, timestamptz, timestamptz
) from public, anon, authenticated;
revoke all on function public.cleanup_bellwire_retention(timestamptz)
  from public, anon, authenticated;
revoke all on function public.claim_private_wake_delivery(
  uuid, timestamptz, integer, integer
) from public, anon, authenticated;

grant execute on function public.account_entitlement_snapshot(uuid, timestamptz)
  to service_role;
grant execute on function public.accept_hosted_event_signal(
  uuid, uuid, text, text, jsonb, text[], timestamptz, timestamptz, text
) to service_role;
grant execute on function public.accept_private_wake_signal(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text
) to service_role;
grant execute on function public.accept_hosted_surface_signal(
  uuid, uuid, text, text, text, text, jsonb, jsonb, integer,
  timestamptz, timestamptz, text
) to service_role;
grant execute on function public.ack_direct_connection_envelope(
  uuid, uuid, text, timestamptz
) to service_role;
grant execute on function public.resolve_delivery_mode_request(
  uuid, uuid, boolean, timestamptz
) to service_role;
grant execute on function public.record_verified_apple_transaction(
  text, text, uuid, text, text, timestamptz, timestamptz, timestamptz,
  text, timestamptz, timestamptz
) to service_role;
grant execute on function public.cleanup_bellwire_retention(timestamptz)
  to service_role;
grant execute on function public.claim_private_wake_delivery(
  uuid, timestamptz, integer, integer
) to service_role;

grant select, insert, update, delete on
  public.private_connection_readiness,
  public.delivery_mode_change_requests,
  public.private_wake_tokens,
  public.private_wakes,
  public.private_wake_deliveries,
  public.billing_entitlements,
  public.apple_transactions,
  public.apple_notification_receipts,
  public.monthly_signal_usage
to service_role;

notify pgrst, 'reload schema';
