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

    @State private var viewModel: TaskEditorViewModel

    init(task: LumaTask) {
        self.task = task
        _viewModel = State(initialValue: TaskEditorViewModel(task: task))
    }

    private var availableSubjects: [AcademicSubject] {
        viewModel.availableSubjects(from: subjects)
    }

    private var availableGradeItems: [SubjectGradeItem] {
        viewModel.availableGradeItems(from: gradeItems)
    }

    private var assignmentIsValid: Bool {
        viewModel.assignmentIsValid(subjects: subjects, gradeItems: gradeItems)
    }

    private var canSave: Bool {
        let dependencyIsValid = viewModel.unlocksTaskID.map { targetID in
            tasks.contains { $0.id == targetID }
                && !TaskDependencyResolver.wouldCreateCycle(
                    sourceTaskID: task.id,
                    targetTaskID: targetID,
                    in: tasks
                )
        } ?? true
        return viewModel.canSave(subjects: subjects, gradeItems: gradeItems)
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
                    if viewModel.area == .university {
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
            TextField("Título", text: $viewModel.title)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(LumaPalette.ink)

            HStack(spacing: 12) {
                Picker("Área", selection: $viewModel.area) {
                    ForEach(LifeArea.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }

                Picker("Energía", selection: $viewModel.energy) {
                    ForEach(EnergyLevel.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Picker("Impacto", selection: $viewModel.impact) {
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
                    get: { viewModel.deadline != nil },
                    set: { viewModel.deadline = $0 ? (.now.addingTimeInterval(86400)) : nil }
                ))

                if viewModel.deadline != nil {
                    DatePicker(
                        "",
                        selection: Binding(get: { viewModel.deadline ?? .now }, set: { viewModel.deadline = $0 }),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }

                Stepper("\(viewModel.estimatedMinutes) min", value: $viewModel.estimatedMinutes, in: 5 ... 480, step: 5)
                Spacer()
            }

            HStack(spacing: 18) {
                Toggle("Completada", isOn: $viewModel.isCompleted)
                Spacer()
            }

            TaskDependencyPicker(
                sourceTaskID: task.id,
                tasks: tasks,
                selectedTaskID: $viewModel.unlocksTaskID
            )
        }
    }

    private var academicFields: some View {
        AcademicTaskFields(
            subjects: availableSubjects,
            gradeItems: availableGradeItems,
            subjectID: $viewModel.academicSubjectID,
            gradeItemID: $viewModel.subjectGradeItemID,
            grade: $viewModel.grade,
            legacyWeight: $viewModel.academicWeight,
            isCompleted: viewModel.isCompleted
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

            TextEditor(text: $viewModel.notes)
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
        viewModel.apply(to: task)

        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        dismiss()
    }
}
