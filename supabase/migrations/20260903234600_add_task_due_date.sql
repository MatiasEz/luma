alter table public.tasks
add column if not exists due_date timestamptz;

comment on column public.tasks.due_date is
  'Real delivery date. Luma plans work before this date; deadline remains the scheduled calendar start.';
