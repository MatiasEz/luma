import SwiftData
import SwiftUI

struct QuickCaptureView: View {
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]

    @State private var draft = ParsedTaskDraft()
    @FocusState private var titleFocused: Bool

    private var activeSubjects: [AcademicSubject] {
        subjects.filter { !$0.isArchived }
    }

    private var activeGradeItems: [SubjectGradeItem] {
        gradeItems.filter { !$0.isArchived }
    }

    private var assignmentIsValid: Bool {
        guard draft.area == .university else { return true }
        if let grade = draft.grade, !(0 ... 10).contains(grade) { return false }
        guard let subjectID = draft.academicSubjectID else {
            return draft.subjectGradeItemID == nil && draft.grade == nil
        }
        guard activeSubjects.contains(where: { $0.id == subjectID }) else { return false }
        guard draft.subjectGradeItemID != nil else { return draft.grade == nil }
        return activeGradeItems.contains {
                $0.id == draft.subjectGradeItemID && $0.subjectID == subjectID
            }
    }

    private var canSave: Bool {
        let dependencyIsValid = draft.unlocksTaskID.map { id in
            tasks.contains { $0.id == id && !$0.isCompleted }
        } ?? true
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assignmentIsValid
            && dependencyIsValid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nuevo pendiente")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Completá los datos que necesites y guardalo.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.55), in: Capsule())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(26)

            ScrollView {
                draftEditor
                    .padding(.horizontal, 26)
                    .padding(.bottom, 20)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaPalette.indigo)
                Button("Guardar pendiente") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(26)
        }
        .background(LumaBackground())
        .environment(\.colorScheme, .light)
        .onAppear { titleFocused = true }
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Título", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(LumaPalette.ink)
                .focused($titleFocused)

            HStack(spacing: 12) {
                Picker("Área", selection: $draft.area) {
                    ForEach(LifeArea.allCases) { area in
                        Label(area.title, systemImage: area.symbol).tag(area)
                    }
                }

                Picker("Energía", selection: $draft.energy) {
                    ForEach(EnergyLevel.allCases) { energy in
                        Text(energy.title).tag(energy)
                    }
                }

                Picker("Impacto", selection: $draft.impact) {
                    ForEach(ImpactType.allCases) { impact in
                        Text(impact.title).tag(impact)
                    }
                }
            }

            HStack(spacing: 16) {
                Toggle("Tiene fecha límite", isOn: Binding(
                    get: { draft.deadline != nil },
                    set: { draft.deadline = $0 ? (.now.addingTimeInterval(86400)) : nil }
                ))

                if draft.deadline != nil {
                    DatePicker(
                        "",
                        selection: Binding(get: { draft.deadline ?? .now }, set: { draft.deadline = $0 }),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }

                Stepper("\(draft.estimatedMinutes) min", value: $draft.estimatedMinutes, in: 5 ... 480, step: 5)
                Spacer()
            }

            if draft.area == .university {
                AcademicTaskFields(
                    subjects: activeSubjects,
                    gradeItems: activeGradeItems,
                    subjectID: $draft.academicSubjectID,
                    gradeItemID: $draft.subjectGradeItemID,
                    grade: $draft.grade,
                    legacyWeight: $draft.academicWeight
                )
            }

            TaskDependencyPicker(
                sourceTaskID: nil,
                tasks: tasks,
                selectedTaskID: $draft.unlocksTaskID
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 16))
    }

    private func save() {
        let task = LumaTask(
            title: draft.title,
            area: draft.area,
            deadline: draft.deadline,
            estimatedMinutes: draft.estimatedMinutes,
            energy: draft.energy,
            impact: draft.impact,
            academicWeight: draft.academicWeight,
            academicSubjectID: draft.area == .university ? draft.academicSubjectID : nil,
            subjectGradeItemID: draft.area == .university ? draft.subjectGradeItemID : nil,
            grade: draft.area == .university ? draft.grade : nil,
            unlocksAnotherTask: draft.unlocksTaskID != nil,
            unlocksTaskID: draft.unlocksTaskID,
            notes: draft.notes
        )
        modelContext.insert(task)
        try? modelContext.save()
        try? calendarService.syncTask(task)
        dismiss()
    }
}

struct MenuBarCaptureView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]
    @State private var input = ""
    @State private var saved = false

    private let parser = NaturalLanguageTaskParser()
    private let learningEngine = BehaviorLearningEngine()

    private var topPriority: PlanRecommendation? {
        let profile = learningEngine.profile(from: focusSessions)
        let planner = TaskPlanner(
            rhythmProfile: appState.learningEnabled ? profile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            academicContexts: AcademicPriorityEngine.contexts(
                subjects: subjects,
                items: gradeItems,
                tasks: tasks
            )
        )
        return appState.dailyRecommendations(from: tasks, planner: planner).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Luma", systemImage: "moon.stars.fill")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.indigo)
                Spacer()
                Text("Captura rápida")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("¿Qué tenés pendiente?", text: $input)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(LumaPalette.ink)
                .onSubmit(save)

            if saved {
                Label("Guardado. Yo lo acomodo.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.sage)
            }

            if let topPriority {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AHORA CONVIENE")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(LumaPalette.sage)
                    Text(topPriority.task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .lineLimit(2)
                    HStack {
                        Text("\(topPriority.suggestedMinutes) min · \(topPriority.task.area.title)")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                        Spacer()
                        Button("Empezar") {
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                            appState.startFocus(
                                for: topPriority.task.id,
                                durationMinutes: topPriority.suggestedMinutes
                            )
                        }
                        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }

            Divider()

            HStack {
                Button("Abrir Luma") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Guardar", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 350)
    }

    private func save() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let draft = parser.parse(input)
        let task = LumaTask(
            title: draft.title,
            area: draft.area,
            deadline: draft.deadline,
            estimatedMinutes: draft.estimatedMinutes,
            energy: draft.energy,
            impact: draft.impact,
            academicWeight: draft.academicWeight,
            unlocksAnotherTask: draft.unlocksAnotherTask,
            notes: draft.notes
        )
        modelContext.insert(task)
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        input = ""
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saved = false
        }
    }
}
