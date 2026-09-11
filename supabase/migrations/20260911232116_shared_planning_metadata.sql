alter table public.tasks add column if not exists planning_details text;
alter table public.academic_exams add column if not exists preparation_start timestamptz;
alter table public.academic_exams add column if not exists preparation_enabled boolean;
alter table public.academic_exams add column if not exists academic_weight double precision check (academic_weight between 0 and 100);

create table if not exists public.sync_tombstones (
  user_id uuid not null references auth.users(id) on delete cascade,
  entity text not null check (entity in ('tasks','focus_sessions','profiles','chat_messages','replan_records','academic_subjects','subject_grade_items','subject_class_meetings','academic_routines','academic_exams','daily_planning_contexts')),
  id uuid not null,
  deleted_at timestamptz not null default now(),
  primary key (user_id, entity, id)
);
alter table public.sync_tombstones enable row level security;
create policy tombstones_own_rows on public.sync_tombstones to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
grant select, insert, update, delete on public.sync_tombstones to authenticated;

create or replace function public.keep_deleted_sync_rows_deleted() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if exists (select 1 from public.sync_tombstones t where t.user_id = new.user_id and t.entity = tg_table_name and t.id = new.id) then
    return null;
  end if;
  return new;
end;
$$;
revoke all on function public.keep_deleted_sync_rows_deleted() from public;
grant execute on function public.keep_deleted_sync_rows_deleted() to authenticated;
do $$
declare entity_name text;
begin
  foreach entity_name in array array['tasks','focus_sessions','profiles','chat_messages','replan_records','academic_subjects','subject_grade_items','subject_class_meetings','academic_routines','academic_exams','daily_planning_contexts']
  loop
    execute format('create trigger keep_deleted_sync_rows_deleted before insert or update on public.%I for each row execute function public.keep_deleted_sync_rows_deleted()', entity_name);
  end loop;
end;
$$;
