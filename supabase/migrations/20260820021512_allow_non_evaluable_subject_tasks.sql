alter table public.tasks
    drop constraint if exists tasks_academic_assignment_check;

alter table public.tasks
    add constraint tasks_academic_assignment_check
    check (
        (academic_subject_id is null and subject_grade_item_id is null and grade is null)
        or
        (
            academic_subject_id is not null
            and (
                (subject_grade_item_id is null and grade is null)
                or subject_grade_item_id is not null
            )
        )
    );

comment on constraint tasks_academic_assignment_check on public.tasks is
    'Allows subject-only organizational tasks, pending evaluations without grades, and graded evaluations.';
