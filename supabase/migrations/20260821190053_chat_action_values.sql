alter table public.chat_messages
    add column if not exists action_date timestamptz,
    add column if not exists action_number double precision;

comment on column public.chat_messages.action_date is
    'Structured date proposed by the local assistant for a reviewable action.';

comment on column public.chat_messages.action_number is
    'Structured numeric value proposed by the local assistant, such as a grade or duration.';
