alter table public.tasks
    add column academic_subject_id uuid,
    add column subject_grade_item_id uuid,
    add column grade numeric(4, 2);

alter table public.subject_grade_items
    add constraint subject_grade_items_user_subject_id_key
    unique (user_id, subject_id, id);

alter table public.tasks
    add constraint tasks_academic_subject_fkey
        foreign key (user_id, academic_subject_id)
        references public.academic_subjects(user_id, id)
        on delete cascade,
    add constraint tasks_subject_grade_item_fkey
        foreign key (user_id, academic_subject_id, subject_grade_item_id)
        references public.subject_grade_items(user_id, subject_id, id)
        on delete cascade,
    add constraint tasks_academic_assignment_check
        check (
            (academic_subject_id is null and subject_grade_item_id is null and grade is null)
            or
            (academic_subject_id is not null and subject_grade_item_id is not null)
        ),
    add constraint tasks_grade_check
        check (grade is null or (grade >= 0 and grade <= 10));

create index tasks_user_academic_assignment_idx
    on public.tasks(user_id, academic_subject_id, subject_grade_item_id)
    where academic_subject_id is not null;
