-- SPDX-License-Identifier: AGPL-3.0-only
create or replace function public.claim_device_binding(
  p_code_hash text,
  p_consumed_at timestamptz,
  p_token_id uuid,
  p_token_name text,
  p_token_hash text,
  p_token_scopes text[],
  p_token_created_at timestamptz
)
returns setof public.agent_tokens
language plpgsql
security definer set search_path = public
as $$
declare
  claimed_binding public.device_bindings%rowtype;
  claimed_token public.agent_tokens%rowtype;
begin
  update public.device_bindings
  set consumed_at = p_consumed_at
  where code_hash = p_code_hash
    and consumed_at is null
    and expires_at > p_consumed_at
  returning * into claimed_binding;

  if not found then
    return;
  end if;

  insert into public.agent_tokens (
    id,
    user_id,
    name,
    token_hash,
    scopes,
    created_at
  ) values (
    p_token_id,
    claimed_binding.user_id,
    p_token_name,
    p_token_hash,
    p_token_scopes,
    p_token_created_at
  )
  returning * into claimed_token;

  return next claimed_token;
end;
$$;

revoke all on function public.claim_device_binding(
  text, timestamptz, uuid, text, text, text[], timestamptz
) from public, anon, authenticated;
grant execute on function public.claim_device_binding(
  text, timestamptz, uuid, text, text, text[], timestamptz
) to service_role;

create or replace function public.claim_delivery(
  p_delivery_id uuid,
  p_claimed_at timestamptz,
  p_lease_seconds integer,
  p_max_attempts integer
)
returns setof public.deliveries
language plpgsql
security definer set search_path = public
as $$
declare
  claimed_delivery public.deliveries%rowtype;
  lease_expired_before timestamptz;
begin
  if p_lease_seconds < 1 or p_max_attempts < 1 then
    return;
  end if;

  lease_expired_before := p_claimed_at - make_interval(secs => p_lease_seconds);

  update public.deliveries
  set
    status = 'failed',
    error_code = 'permanent:LeaseExpired',
    error_message = 'Delivery worker lease expired after the maximum number of attempts',
    updated_at = p_claimed_at
  where id = p_delivery_id
    and status = 'queued'
    and attempt_count >= p_max_attempts
    and updated_at <= lease_expired_before;

  update public.deliveries
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

revoke all on function public.claim_delivery(uuid, timestamptz, integer, integer)
from public, anon, authenticated;
grant execute on function public.claim_delivery(uuid, timestamptz, integer, integer)
to service_role;

create or replace view public.active_notification_surfaces
with (security_invoker = true)
as
select latest.*
from (
  select distinct on (project_id, event_type) *
  from public.notification_surfaces
  order by project_id, event_type, version desc
) as latest
where latest.enabled = true;
