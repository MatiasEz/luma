create table if not exists public.profiles (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    selected_areas text not null default '',
    gentle_weekdays text not null default '',
    energy_peak text not null default 'afternoon',
    usual_start_minute_of_day integer not null default 1020,
    usual_available_minutes integer not null default 120,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id),
    constraint profiles_start_minute_check check (usual_start_minute_of_day between 0 and 1439),
    constraint profiles_available_minutes_check check (usual_available_minutes between 30 and 480)
);

create table if not exists public.tasks (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    title text not null,
    area text not null,
    deadline timestamptz,
    estimated_minutes integer not null,
    energy text not null,
    impact text not null,
    academic_weight double precision,
    status text not null,
    created_at timestamptz not null,
    completed_at timestamptz,
    postponement_count integer not null default 0,
    unlocks_another_task boolean not null default false,
    notes text not null default '',
    focused_minutes integer not null default 0,
    focus_session_count integer not null default 0,
    last_focused_at timestamptz,
    updated_at timestamptz not null default now(),
    constraint tasks_estimated_minutes_check check (estimated_minutes > 0),
    constraint tasks_status_check check (status in ('pending', 'completed'))
);

create table if not exists public.focus_sessions (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    task_id uuid not null,
    task_title text not null,
    area text not null,
    planned_minutes integer not null,
    actual_minutes integer not null,
    started_at timestamptz not null,
    ended_at timestamptz not null,
    energy_preference text not null,
    completed_task boolean not null default false,
    ignored_from_learning boolean not null default false
);

create table if not exists public.chat_messages (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    role text not null,
    text text not null,
    evidence text not null default '',
    created_at timestamptz not null,
    action_id uuid,
    action_kind text,
    action_label text,
    action_task_id uuid,
    action_energy text,
    action_available_minutes integer,
    action_duration_minutes integer,
    applied_at timestamptz,
    constraint chat_role_check check (role in ('user', 'assistant'))
);

create table if not exists public.replan_records (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null,
    source text not null,
    reason text not null,
    before_energy text not null,
    after_energy text not null,
    before_available_minutes integer not null,
    after_available_minutes integer not null,
    before_task_ids text not null default '',
    after_task_ids text not null default '',
    before_agenda text not null default '',
    after_agenda text not null default '',
    change_summary text not null default ''
);

create index if not exists tasks_user_updated_idx on public.tasks(user_id, updated_at desc);
create index if not exists focus_sessions_user_ended_idx on public.focus_sessions(user_id, ended_at desc);
create index if not exists chat_messages_user_created_idx on public.chat_messages(user_id, created_at);
create index if not exists replan_records_user_created_idx on public.replan_records(user_id, created_at desc);

grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.tasks to authenticated;
grant select, insert, update, delete on public.focus_sessions to authenticated;
grant select, insert, update, delete on public.chat_messages to authenticated;
grant select, insert, update, delete on public.replan_records to authenticated;

alter table public.profiles enable row level security;
alter table public.tasks enable row level security;
alter table public.focus_sessions enable row level security;
alter table public.chat_messages enable row level security;
alter table public.replan_records enable row level security;

create policy "profiles_own_rows" on public.profiles
    for all to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create policy "tasks_own_rows" on public.tasks
    for all to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create policy "focus_sessions_own_rows" on public.focus_sessions
    for all to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create policy "chat_messages_own_rows" on public.chat_messages
    for all to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create policy "replan_records_own_rows" on public.replan_records
    for all to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);
