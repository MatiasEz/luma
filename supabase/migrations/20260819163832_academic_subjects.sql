create table public.academic_subjects (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    is_archived boolean not null default false,
    constraint academic_subjects_name_check
        check (char_length(btrim(name)) between 1 and 120),
    constraint academic_subjects_updated_at_check
        check (updated_at >= created_at),
    constraint academic_subjects_user_id_id_key
        unique (user_id, id)
);

create table public.subject_grade_items (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    subject_id uuid not null,
    title text not null,
    weight_percent numeric(5, 2) not null,
    created_at timestamptz not null,
    updated_at timestamptz not null,
    is_archived boolean not null default false,
    constraint subject_grade_items_subject_fkey
        foreign key (user_id, subject_id)
        references public.academic_subjects(user_id, id)
        on delete cascade,
    constraint subject_grade_items_title_check
        check (char_length(btrim(title)) between 1 and 120),
    constraint subject_grade_items_weight_check
        check (weight_percent > 0 and weight_percent <= 100),
    constraint subject_grade_items_updated_at_check
        check (updated_at >= created_at)
);

create index academic_subjects_user_updated_idx
    on public.academic_subjects(user_id, updated_at desc);

create index subject_grade_items_user_subject_updated_idx
    on public.subject_grade_items(user_id, subject_id, updated_at desc);

revoke all on public.academic_subjects from anon, authenticated;
revoke all on public.subject_grade_items from anon, authenticated;

grant select, insert, update on public.academic_subjects to authenticated;
grant select, insert, update on public.subject_grade_items to authenticated;

alter table public.academic_subjects enable row level security;
alter table public.subject_grade_items enable row level security;

create policy "academic_subjects_select_own"
    on public.academic_subjects
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

create policy "academic_subjects_insert_own"
    on public.academic_subjects
    for insert
    to authenticated
    with check ((select auth.uid()) = user_id);

create policy "academic_subjects_update_own"
    on public.academic_subjects
    for update
    to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

create policy "subject_grade_items_select_own"
    on public.subject_grade_items
    for select
    to authenticated
    using ((select auth.uid()) = user_id);

create policy "subject_grade_items_insert_own"
    on public.subject_grade_items
    for insert
    to authenticated
    with check ((select auth.uid()) = user_id);

create policy "subject_grade_items_update_own"
    on public.subject_grade_items
    for update
    to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);
