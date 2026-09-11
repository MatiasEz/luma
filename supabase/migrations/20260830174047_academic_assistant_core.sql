alter table public.academic_subjects
    add column if not exists color_hex text not null default '#59639A',
    add column if not exists syllabus_raw text not null default '';

alter table public.tasks
    add column if not exists source_type text,
    add column if not exists source_id uuid,
    add column if not exists source_occurrence_date timestamptz,
    add column if not exists study_stage text;

alter table public.tasks
    drop constraint if exists tasks_source_type_check;
alter table public.tasks
    add constraint tasks_source_type_check
        check (source_type is null or source_type in ('routine', 'examStudy', 'rest'));

alter table public.tasks
    drop constraint if exists tasks_study_stage_check;
alter table public.tasks
    add constraint tasks_study_stage_check
        check (study_stage is null or study_stage in ('read', 'summarize', 'questions', 'review', 'finalReview'));

create table if not exists public.subject_class_meetings (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    subject_id uuid not null,
    weekday integer not null check (weekday between 1 and 7),
    start_minute_of_day integer not null check (start_minute_of_day between 0 and 1439),
    end_minute_of_day integer not null check (end_minute_of_day between 1 and 1440),
    location text not null default '',
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint subject_class_meetings_time_check check (end_minute_of_day > start_minute_of_day),
    constraint subject_class_meetings_subject_fkey
        foreign key (user_id, subject_id)
        references public.academic_subjects(user_id, id)
        on delete cascade
);

create table if not exists public.academic_routines (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    title text not null check (char_length(btrim(title)) between 1 and 160),
    subject_id uuid,
    weekday integer not null check (weekday between 1 and 7),
    minute_of_day integer check (minute_of_day between 0 and 1439),
    activity_type text not null check (activity_type in ('assignment', 'reading', 'laboratory', 'classMeeting', 'study')),
    estimated_minutes integer not null check (estimated_minutes between 5 and 900),
    start_date timestamptz not null,
    end_date timestamptz,
    is_paused boolean not null default false,
    pause_during_vacation boolean not null default true,
    notes text not null default '',
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint academic_routines_date_check check (end_date is null or end_date >= start_date),
    constraint academic_routines_subject_fkey
        foreign key (user_id, subject_id)
        references public.academic_subjects(user_id, id)
        on delete cascade
);

create table if not exists public.academic_exams (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    title text not null check (char_length(btrim(title)) between 1 and 160),
    subject_id uuid not null,
    date timestamptz not null,
    topics_raw text not null default '',
    importance text not null check (importance in ('normal', 'important', 'critical')),
    preparation_minutes integer not null check (preparation_minutes between 30 and 3000),
    is_archived boolean not null default false,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    constraint academic_exams_subject_fkey
        foreign key (user_id, subject_id)
        references public.academic_subjects(user_id, id)
        on delete cascade
);

create table if not exists public.daily_planning_contexts (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    day timestamptz not null,
    energy text not null check (energy in ('normal', 'tired', 'energized')),
    available_minutes integer not null check (available_minutes between 0 and 720),
    planning_mode text not null check (planning_mode in ('gentle', 'realistic', 'intense')),
    rest_counts boolean not null default true,
    updated_at timestamptz not null
);

create index if not exists tasks_user_source_idx
    on public.tasks(user_id, source_type, source_id, source_occurrence_date);
create index if not exists subject_class_meetings_user_subject_idx
    on public.subject_class_meetings(user_id, subject_id, weekday);
create index if not exists academic_routines_user_weekday_idx
    on public.academic_routines(user_id, weekday, is_paused);
create index if not exists academic_exams_user_date_idx
    on public.academic_exams(user_id, date) where not is_archived;
create index if not exists daily_planning_contexts_user_day_idx
    on public.daily_planning_contexts(user_id, day desc);

revoke all on public.subject_class_meetings from anon, authenticated;
revoke all on public.academic_routines from anon, authenticated;
revoke all on public.academic_exams from anon, authenticated;
revoke all on public.daily_planning_contexts from anon, authenticated;

grant select, insert, update, delete on public.subject_class_meetings to authenticated;
grant select, insert, update, delete on public.academic_routines to authenticated;
grant select, insert, update, delete on public.academic_exams to authenticated;
grant select, insert, update, delete on public.daily_planning_contexts to authenticated;

alter table public.subject_class_meetings enable row level security;
alter table public.academic_routines enable row level security;
alter table public.academic_exams enable row level security;
alter table public.daily_planning_contexts enable row level security;

create policy "subject_class_meetings_select_own" on public.subject_class_meetings
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "subject_class_meetings_insert_own" on public.subject_class_meetings
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "subject_class_meetings_update_own" on public.subject_class_meetings
    for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "subject_class_meetings_delete_own" on public.subject_class_meetings
    for delete to authenticated using ((select auth.uid()) = user_id);

create policy "academic_routines_select_own" on public.academic_routines
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "academic_routines_insert_own" on public.academic_routines
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "academic_routines_update_own" on public.academic_routines
    for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "academic_routines_delete_own" on public.academic_routines
    for delete to authenticated using ((select auth.uid()) = user_id);

create policy "academic_exams_select_own" on public.academic_exams
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "academic_exams_insert_own" on public.academic_exams
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "academic_exams_update_own" on public.academic_exams
    for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "academic_exams_delete_own" on public.academic_exams
    for delete to authenticated using ((select auth.uid()) = user_id);

create policy "daily_planning_contexts_select_own" on public.daily_planning_contexts
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "daily_planning_contexts_insert_own" on public.daily_planning_contexts
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "daily_planning_contexts_update_own" on public.daily_planning_contexts
    for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "daily_planning_contexts_delete_own" on public.daily_planning_contexts
    for delete to authenticated using ((select auth.uid()) = user_id);
