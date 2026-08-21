import SwiftData
import SwiftUI

struct TaskEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]

    let task: LumaTask

    @State private var title: String
    @State private var area: LifeArea
    @State private var deadline: Date?
    @State private var estimatedMinutes: Int
    @State private var energy: EnergyLevel
    @State private var impact: ImpactType
    @State private var academicWeight: Double?
    @State private var academicSubjectID: UUID?
    @State private var subjectGradeItemID: UUID?
    @State private var grade: Double?
    @State private var unlocksTaskID: UUID?
    @State private var notes: String
    @State private var isCompleted: Bool

    init(task: LumaTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _area = State(initialValue: task.area)
        _deadline = State(initialValue: task.deadline)
        _estimatedMinutes = State(initialValue: task.estimatedMinutes)
        _energy = State(initialValue: task.energy)
        _impact = State(initialValue: task.impact)
        _academicWeight = State(initialValue: task.academicWeight)
        _academicSubjectID = State(initialValue: task.academicSubjectID)
        _subjectGradeItemID = State(initialValue: task.subjectGradeItemID)
        _grade = State(initialValue: task.grade)
        _unlocksTaskID = State(initialValue: task.unlocksTaskID)
        _notes = State(initialValue: task.notes)
        _isCompleted = State(initialValue: task.isCompleted)
    }

    private var availableSubjects: [AcademicSubject] {
        subjects.filter { !$0.isArchived || $0.id == academicSubjectID }
    }

    private var availableGradeItems: [SubjectGradeItem] {
        gradeItems.filter { !$0.isArchived || $0.id == subjectGradeItemID }
    }

    private var assignmentIsValid: Bool {
        guard area == .university else { return true }
        if let grade, !(0 ... 10).contains(grade) { return false }
        guard let academicSubjectID else {
            return subjectGradeItemID == nil && grade == nil
        }
        guard availableSubjects.contains(where: { $0.id == academicSubjectID }) else { return false }
        guard subjectGradeItemID != nil else { return grade == nil }
        return availableGradeItems.contains {
                $0.id == subjectGradeItemID && $0.subjectID == academicSubjectID
            }
    }

    private var canSave: Bool {
        let dependencyIsValid = unlocksTaskID.map { targetID in
            tasks.contains { $0.id == targetID }
                && !TaskDependencyResolver.wouldCreateCycle(
                    sourceTaskID: task.id,
                    targetTaskID: targetID,
                    in: tasks
                )
        } ?? true
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assignmentIsValid
            && dependencyIsValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    mainFields
                    planningFields
                    if area == .university {
                        academicFields
                    }
                    notesField
                }
                .padding(18)
                .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 18))
            }

            footer
        }
        .padding(26)
        .background(LumaBackground())
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Editar pendiente")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Ajustá lo necesario. El plan de hoy conserva su lugar.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
            Button("Cerrar") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(LumaPalette.secondaryInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.55), in: Capsule())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var mainFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Título", text: $title)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(LumaPalette.ink)

            HStack(spacing: 12) {
                Picker("Área", selection: $area) {
                    ForEach(LifeArea.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }

                Picker("Energía", selection: $energy) {
                    ForEach(EnergyLevel.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Picker("Impacto", selection: $impact) {
                    ForEach(ImpactType.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
        }
    }

    private var planningFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Toggle("Tiene fecha límite", isOn: Binding(
                    get: { deadline != nil },
                    set: { deadline = $0 ? (.now.addingTimeInterval(86400)) : nil }
                ))

                if deadline != nil {
                    DatePicker(
                        "",
                        selection: Binding(get: { deadline ?? .now }, set: { deadline = $0 }),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }

                Stepper("\(estimatedMinutes) min", value: $estimatedMinutes, in: 5 ... 480, step: 5)
                Spacer()
            }

            HStack(spacing: 18) {
                Toggle("Completada", isOn: $isCompleted)
                Spacer()
            }

            TaskDependencyPicker(
                sourceTaskID: task.id,
                tasks: tasks,
                selectedTaskID: $unlocksTaskID
            )
        }
    }

    private var academicFields: some View {
        AcademicTaskFields(
            subjects: availableSubjects,
            gradeItems: availableGradeItems,
            subjectID: $academicSubjectID,
            gradeItemID: $subjectGradeItemID,
            grade: $grade,
            legacyWeight: $academicWeight,
            isCompleted: isCompleted
        )
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notas")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                Spacer()
                if task.postponementCount > 0 {
                    Text("Postergada \(task.postponementCount) veces")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.terracotta)
                }
            }

            TextEditor(text: $notes)
                .font(.body)
                .foregroundColor(LumaPalette.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 90)
                .background(Color.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(LumaPalette.indigo.opacity(0.12))
                }
        }
    }

    private var footer: some View {
        HStack {
            Label("Guardado local con respaldo en Supabase", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(LumaPalette.sage)
            Spacer()
            Button("Cancelar") { dismiss() }
                .buttonStyle(.borderless)
            Button("Guardar cambios") { save() }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

    private func save() {
        task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.area = area
        task.deadline = deadline
        task.estimatedMinutes = estimatedMinutes
        task.energy = energy
        task.impact = impact
        task.academicWeight = area == .university ? academicWeight : nil
        task.academicSubjectID = area == .university ? academicSubjectID : nil
        task.subjectGradeItemID = area == .university ? subjectGradeItemID : nil
        task.grade = area == .university ? grade : nil
        task.unlocksAnotherTask = unlocksTaskID != nil
        task.unlocksTaskID = unlocksTaskID
        task.notes = notes

        if isCompleted, !task.isCompleted {
            task.markCompleted()
        } else if !isCompleted, task.isCompleted {
            task.restore()
        }

        task.touch()

        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        dismiss()
    }
}
