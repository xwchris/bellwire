create table public.live_surfaces (
  id uuid primary key default extensions.gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  surface_key text not null check (
    char_length(surface_key) between 1 and 80
    and surface_key ~ '^[a-z0-9]+([._-][a-z0-9]+)*$'
  ),
  type text not null check (type in (
    'stats', 'metrics', 'segmented_progress', 'progress', 'alert', 'timer'
  )),
  title text not null check (char_length(title) between 1 and 80),
  subtitle text check (subtitle is null or char_length(subtitle) <= 120),
  content jsonb not null check (jsonb_typeof(content) = 'object'),
  action jsonb check (action is null or jsonb_typeof(action) = 'object'),
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id, surface_key)
);

create index live_surfaces_project_updated_idx
on public.live_surfaces(project_id, updated_at desc);

alter table public.live_surfaces enable row level security;

create policy "live_surfaces_read_own" on public.live_surfaces for select to authenticated
using (exists (
  select 1 from public.projects
  where projects.id = live_surfaces.project_id and projects.user_id = auth.uid()
));

grant select on public.live_surfaces to authenticated;
grant select, insert, update, delete on public.live_surfaces to service_role;
