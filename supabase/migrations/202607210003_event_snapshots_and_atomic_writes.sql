-- SPDX-License-Identifier: AGPL-3.0-only
alter table public.events
add column sensitive_fields text[];

-- Events received before this column existed cannot be reconstructed exactly.
-- Treat every historical payload key as sensitive so later schema edits can never expose it.
update public.events
set sensitive_fields = array(
  select jsonb_object_keys(events.data)
)
where sensitive_fields is null;

alter table public.events
alter column sensitive_fields set not null;

create or replace function public.protect_event_sensitive_fields()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and new.sensitive_fields is null then
    new.sensitive_fields := array(select jsonb_object_keys(new.data));
  elsif tg_op = 'UPDATE' and new.sensitive_fields is distinct from old.sensitive_fields then
    raise exception 'event sensitive_fields is immutable' using errcode = '22000';
  end if;
  return new;
end;
$$;

create trigger protect_event_sensitive_fields
before insert or update on public.events
for each row execute function public.protect_event_sensitive_fields();

create or replace function public.record_queue_unavailable(
  p_delivery_id uuid,
  p_expected_status text,
  p_expected_attempt_count integer,
  p_expected_updated_at timestamptz,
  p_failed_at timestamptz,
  p_error_message text
)
returns setof public.deliveries
language sql
security definer set search_path = public
as $$
  update public.deliveries
  set
    status = 'failed',
    error_code = 'retryable:QueueUnavailable',
    error_message = left(p_error_message, 240),
    updated_at = p_failed_at
  where id = p_delivery_id
    and status = p_expected_status
    and attempt_count = p_expected_attempt_count
    and updated_at = p_expected_updated_at
    and status = 'queued'
    and attempt_count = 0
  returning *;
$$;

revoke all on function public.record_queue_unavailable(
  uuid, text, integer, timestamptz, timestamptz, text
) from public, anon, authenticated;
grant execute on function public.record_queue_unavailable(
  uuid, text, integer, timestamptz, timestamptz, text
) to service_role;

create or replace function public.save_event_schema_version(
  p_id uuid,
  p_project_id uuid,
  p_event_type text,
  p_fields jsonb,
  p_status text,
  p_created_at timestamptz
)
returns setof public.event_schemas
language plpgsql
security definer set search_path = public
as $$
declare
  next_version integer;
begin
  perform 1 from public.projects where id = p_project_id for update;
  if not found then return; end if;

  select coalesce(max(version), 0) + 1
  into next_version
  from public.event_schemas
  where project_id = p_project_id and event_type = p_event_type;

  return query
  insert into public.event_schemas (
    id, project_id, event_type, fields, version, status, created_at
  ) values (
    p_id, p_project_id, p_event_type, p_fields, next_version, p_status, p_created_at
  )
  returning *;
end;
$$;

revoke all on function public.save_event_schema_version(
  uuid, uuid, text, jsonb, text, timestamptz
) from public, anon, authenticated;
grant execute on function public.save_event_schema_version(
  uuid, uuid, text, jsonb, text, timestamptz
) to service_role;

create or replace function public.save_notification_surface_version(
  p_id uuid,
  p_project_id uuid,
  p_event_type text,
  p_title_template text,
  p_body_template text,
  p_subtitle_template text,
  p_sound text,
  p_group_name text,
  p_priority text,
  p_enabled boolean,
  p_created_at timestamptz
)
returns setof public.notification_surfaces
language plpgsql
security definer set search_path = public
as $$
declare
  next_version integer;
begin
  perform 1 from public.projects where id = p_project_id for update;
  if not found then return; end if;

  select coalesce(max(version), 0) + 1
  into next_version
  from public.notification_surfaces
  where project_id = p_project_id and event_type = p_event_type;

  return query
  insert into public.notification_surfaces (
    id, project_id, event_type, type, title_template, body_template,
    subtitle_template, sound, group_name, priority, enabled, version, created_at
  ) values (
    p_id, p_project_id, p_event_type, 'notification', p_title_template, p_body_template,
    p_subtitle_template, p_sound, p_group_name, p_priority, p_enabled, next_version, p_created_at
  )
  returning *;
end;
$$;

revoke all on function public.save_notification_surface_version(
  uuid, uuid, text, text, text, text, text, text, text, boolean, timestamptz
) from public, anon, authenticated;
grant execute on function public.save_notification_surface_version(
  uuid, uuid, text, text, text, text, text, text, text, boolean, timestamptz
) to service_role;

create or replace function public.save_live_surface_version(
  p_id uuid,
  p_project_id uuid,
  p_surface_key text,
  p_type text,
  p_title text,
  p_subtitle text,
  p_content jsonb,
  p_action jsonb,
  p_created_at timestamptz,
  p_updated_at timestamptz
)
returns setof public.live_surfaces
language plpgsql
security definer set search_path = public
as $$
declare
  saved_surface public.live_surfaces%rowtype;
begin
  perform 1 from public.projects where id = p_project_id for update;
  if not found then return; end if;

  update public.live_surfaces
  set
    type = p_type,
    title = p_title,
    subtitle = p_subtitle,
    content = p_content,
    action = p_action,
    version = version + 1,
    updated_at = p_updated_at
  where project_id = p_project_id and surface_key = p_surface_key
  returning * into saved_surface;

  if found then
    return next saved_surface;
    return;
  end if;

  insert into public.live_surfaces (
    id, project_id, surface_key, type, title, subtitle, content, action,
    version, created_at, updated_at
  ) values (
    p_id, p_project_id, p_surface_key, p_type, p_title, p_subtitle, p_content, p_action,
    1, p_created_at, p_updated_at
  )
  returning * into saved_surface;
  return next saved_surface;
end;
$$;

revoke all on function public.save_live_surface_version(
  uuid, uuid, text, text, text, text, jsonb, jsonb, timestamptz, timestamptz
) from public, anon, authenticated;
grant execute on function public.save_live_surface_version(
  uuid, uuid, text, text, text, text, jsonb, jsonb, timestamptz, timestamptz
) to service_role;
