create table if not exists public.homework_sessions (
  id text primary key,
  child_id text not null,
  family_id text not null default '',
  homework_id text not null,
  date text not null,
  subject text not null,
  start_at bigint not null,
  end_at bigint,
  seconds integer not null default 0,
  created_at bigint not null,
  updated_at bigint not null,
  is_deleted boolean not null default false
);

create index if not exists idx_homework_sessions_child_date on public.homework_sessions(child_id, date);

alter table public.homework_sessions enable row level security;

drop policy if exists anon_all_homework_sessions on public.homework_sessions;
create policy anon_all_homework_sessions on public.homework_sessions for all to anon using (true) with check (true);

drop policy if exists auth_all_homework_sessions on public.homework_sessions;
create policy auth_all_homework_sessions on public.homework_sessions for all to authenticated using (true) with check (true);

grant select, insert, update, delete on public.homework_sessions to anon, authenticated;
grant select, insert, update, delete on public.homework_sessions to service_role;
