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
  quota_row public.ingest_rate_limits%rowtype;
  request_time timestamptz := clock_timestamp();
begin
  if p_limit < 1 or p_window_seconds < 1 then
    return false;
  end if;

  insert into public.ingest_rate_limits(key, window_started_at, request_count)
  values (p_key, request_time, 1)
  on conflict (key) do update
  set
    window_started_at = case
      when public.ingest_rate_limits.window_started_at
        + make_interval(secs => p_window_seconds) <= request_time
      then request_time
      else public.ingest_rate_limits.window_started_at
    end,
    request_count = case
      when public.ingest_rate_limits.window_started_at
        + make_interval(secs => p_window_seconds) <= request_time
      then 1
      else public.ingest_rate_limits.request_count + 1
    end
  returning * into quota_row;

  return quota_row.request_count <= p_limit;
end;
$$;

revoke all on function public.consume_ingest_quota(text, integer, integer)
from public, anon, authenticated;
grant execute on function public.consume_ingest_quota(text, integer, integer)
to service_role;
