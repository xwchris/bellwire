-- SPDX-License-Identifier: AGPL-3.0-only
alter table public.projects
  add column if not exists display_order integer;

with ranked_projects as (
  select id, row_number() over (
    partition by user_id
    order by updated_at desc, id asc
  ) - 1 as position
  from public.projects
)
update public.projects as projects
set display_order = ranked_projects.position
from ranked_projects
where projects.id = ranked_projects.id
  and projects.display_order is null;

alter table public.projects
  alter column display_order set default 0,
  alter column display_order set not null;

alter table public.projects
  drop constraint if exists projects_display_order_check;

alter table public.projects
  add constraint projects_display_order_check
  check (display_order between 0 and 1000000);

create index if not exists projects_user_display_order_idx
on public.projects(user_id, display_order asc, id asc);

alter table public.live_surfaces
  add column if not exists display_order integer;

with ranked_surfaces as (
  select id, row_number() over (
    partition by project_id
    order by updated_at desc, id asc
  ) - 1 as position
  from public.live_surfaces
)
update public.live_surfaces as surfaces
set display_order = ranked_surfaces.position
from ranked_surfaces
where surfaces.id = ranked_surfaces.id
  and surfaces.display_order is null;

alter table public.live_surfaces
  alter column display_order set default 0,
  alter column display_order set not null;

alter table public.live_surfaces
  drop constraint if exists live_surfaces_display_order_check;

alter table public.live_surfaces
  add constraint live_surfaces_display_order_check
  check (display_order between 0 and 1000000);

create index if not exists live_surfaces_project_display_order_idx
on public.live_surfaces(project_id, display_order asc, id asc);

drop function if exists public.save_live_surface_version(
  uuid, uuid, text, text, text, text, jsonb, jsonb, timestamptz, timestamptz
);

create function public.save_live_surface_version(
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
    display_order, version, created_at, updated_at
  ) values (
    p_id, p_project_id, p_surface_key, p_type, p_title, p_subtitle, p_content, p_action,
    p_display_order, 1, p_created_at, p_updated_at
  )
  returning * into saved_surface;
  return next saved_surface;
end;
$$;

revoke all on function public.save_live_surface_version(
  uuid, uuid, text, text, text, text, jsonb, jsonb, integer, timestamptz, timestamptz
) from public, anon, authenticated;
grant execute on function public.save_live_surface_version(
  uuid, uuid, text, text, text, text, jsonb, jsonb, integer, timestamptz, timestamptz
) to service_role;

notify pgrst, 'reload schema';
