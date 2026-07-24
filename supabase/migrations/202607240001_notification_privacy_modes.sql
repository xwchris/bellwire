-- SPDX-License-Identifier: AGPL-3.0-only
create table public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  mode text not null default 'local_enrichment'
    check (mode in ('generic', 'local_enrichment', 'hosted_detailed')),
  updated_at timestamptz not null default now()
);

alter table public.notification_preferences enable row level security;

create policy "notification_preferences_own"
on public.notification_preferences
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

comment on table public.notification_preferences is
  'Account-wide notification privacy mode. Local enrichment is the privacy-preserving default.';

notify pgrst, 'reload schema';
