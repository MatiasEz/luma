alter table public.academic_subjects
    add column target_grade numeric(4, 2);

alter table public.academic_subjects
    add constraint academic_subjects_target_grade_check
    check (target_grade is null or (target_grade >= 0 and target_grade <= 10));

comment on column public.academic_subjects.target_grade is
    'Optional final grade goal selected by the user, on a 0 to 10 scale.';
