-- SPDX-License-Identifier: AGPL-3.0-only
alter table public.projects
  add column if not exists logo_url text;

alter table public.projects
  drop constraint if exists projects_logo_url_check;

alter table public.projects
  add constraint projects_logo_url_check check (
    logo_url is null
    or (
      char_length(logo_url) between 1 and 2048
      and logo_url ~ '^https://[^[:space:]]+$'
    )
  );

comment on column public.projects.logo_url is
  'Public HTTPS project logo used by Bellwire app avatars and rich notification attachments.';
