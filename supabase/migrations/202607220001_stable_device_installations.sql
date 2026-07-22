alter table public.devices
  add column if not exists installation_id uuid;

update public.devices
set installation_id = id
where installation_id is null;

alter table public.devices
  alter column installation_id set not null;

create unique index if not exists devices_user_installation_unique
  on public.devices (user_id, installation_id);

create or replace function public.register_device(
  p_id uuid,
  p_user_id uuid,
  p_installation_id uuid,
  p_name text,
  p_apns_token text,
  p_app_version text,
  p_last_active_at timestamptz,
  p_push_enabled boolean,
  p_created_at timestamptz
)
returns setof public.devices
language plpgsql
security invoker
set search_path = ''
as $$
declare
  saved public.devices;
begin
  update public.devices
  set user_id = p_user_id,
      installation_id = p_installation_id,
      name = p_name,
      platform = 'ios',
      app_version = p_app_version,
      last_active_at = p_last_active_at,
      push_enabled = p_push_enabled
  where apns_token = p_apns_token
  returning * into saved;

  if found then
    return next saved;
    return;
  end if;

  update public.devices
  set name = p_name,
      platform = 'ios',
      apns_token = p_apns_token,
      app_version = p_app_version,
      last_active_at = p_last_active_at,
      push_enabled = p_push_enabled
  where user_id = p_user_id
    and installation_id = p_installation_id
  returning * into saved;

  if found then
    return next saved;
    return;
  end if;

  insert into public.devices (
    id,
    user_id,
    installation_id,
    name,
    platform,
    apns_token,
    app_version,
    last_active_at,
    push_enabled,
    created_at
  ) values (
    p_id,
    p_user_id,
    p_installation_id,
    p_name,
    'ios',
    p_apns_token,
    p_app_version,
    p_last_active_at,
    p_push_enabled,
    p_created_at
  )
  returning * into saved;

  return next saved;
end;
$$;

revoke all on function public.register_device(
  uuid, uuid, uuid, text, text, text, timestamptz, boolean, timestamptz
) from public, anon, authenticated;

grant execute on function public.register_device(
  uuid, uuid, uuid, text, text, text, timestamptz, boolean, timestamptz
) to service_role;

comment on column public.devices.installation_id is
  'Stable installation identifier stored in the iOS Keychain and reused across APNs token rotations.';
