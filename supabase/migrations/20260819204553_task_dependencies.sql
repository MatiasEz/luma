alter table public.tasks
  add column if not exists unlocks_task_id uuid;

alter table public.tasks
  add constraint tasks_user_id_id_unique unique (user_id, id);

alter table public.tasks
  add constraint tasks_unlocks_task_fkey
  foreign key (user_id, unlocks_task_id)
  references public.tasks (user_id, id)
  on delete set null (unlocks_task_id);

alter table public.tasks
  add constraint tasks_cannot_unlock_itself
  check (unlocks_task_id is null or unlocks_task_id <> id);

create index tasks_user_unlocks_task_id_idx
  on public.tasks (user_id, unlocks_task_id)
  where unlocks_task_id is not null;
