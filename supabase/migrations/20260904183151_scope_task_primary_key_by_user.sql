-- A task UUID is generated locally and is only required to be unique inside
-- its owner's data. Keeping `id` as the global primary key made an upsert for
-- one user collide with a row owned by another user, which RLS correctly
-- rejected. Scope conflict detection by both owner and local UUID instead.
do $$
declare
    current_primary_key text;
begin
    select pg_get_constraintdef(oid)
      into current_primary_key
      from pg_constraint
     where conrelid = 'public.tasks'::regclass
       and conname = 'tasks_pkey';

    if current_primary_key = 'PRIMARY KEY (id)' then
        alter table public.tasks drop constraint tasks_pkey;
        alter table public.tasks
            add constraint tasks_pkey primary key (user_id, id);
    elsif current_primary_key is distinct from 'PRIMARY KEY (user_id, id)' then
        raise exception 'Unexpected tasks primary key: %', current_primary_key;
    end if;
end
$$;

-- The old composite unique constraint becomes redundant once the primary key
-- uses the same columns. Recreate the self-reference against the primary key
-- before removing the duplicate index.
do $$
begin
    if exists (
        select 1
          from pg_constraint
         where conrelid = 'public.tasks'::regclass
           and conname = 'tasks_user_id_id_unique'
    ) then
        alter table public.tasks
            drop constraint if exists tasks_unlocks_task_fkey;
        alter table public.tasks
            drop constraint tasks_user_id_id_unique;
        alter table public.tasks
            add constraint tasks_unlocks_task_fkey
            foreign key (user_id, unlocks_task_id)
            references public.tasks(user_id, id)
            on delete set null (unlocks_task_id);
    end if;
end
$$;
