import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt, order: .reverse) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]
    @State private var selectedArea: LifeArea?
    @State private var showCompleted = false
    @State private var editingTask: LumaTask?

    private var awaitingGradeTasks: [LumaTask] {
        tasks.filter { task in
            task.academicEvaluationStatus == .awaitingGrade
                && (selectedArea == nil || task.area == selectedArea)
        }
    }

    private var regularTasks: [LumaTask] {
        tasks.filter { task in
            task.academicEvaluationStatus != .awaitingGrade
                && (showCompleted || !task.isCompleted)
                && (selectedArea == nil || task.area == selectedArea)
        }
    }

    private var awaitingGradeCount: Int {
        tasks.filter { $0.academicEvaluationStatus == .awaitingGrade }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) {
                        inboxTitle
                        Spacer(minLength: 14)
                        addButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        inboxTitle
                        addButton
                    }
                }

                filters
                awaitingGradesSection
                Divider().opacity(0.45)
                regularTasksSection
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Inbox")
        .sheet(isPresented: Binding(
            get: { editingTask != nil },
            set: { if !$0 { editingTask = nil } }
        )) {
            if let editingTask {
                TaskEditorView(task: editingTask)
                    .frame(width: 720, height: 690)
            }
        }
    }

    private var awaitingGradesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                eyebrow: "Seguimiento académico",
                title: "Esperando nota",
                trailing: awaitingGradeTasks.count == 1
                    ? "1 evaluación"
                    : "\(awaitingGradeTasks.count) evaluaciones"
            )

            Text("Son evaluaciones que ya completaste, pero todavía no tienen calificación. No afectan tu promedio hasta que cargues la nota.")
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if awaitingGradeTasks.isEmpty {
                Label("No hay evaluaciones esperando nota.", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LumaPalette.sage)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LumaPalette.sage.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(awaitingGradeTasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
    }

    private var regularTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                eyebrow: "Por hacer",
                title: "Pendientes",
                trailing: "\(regularTasks.count) tareas"
            )

            if regularTasks.isEmpty {
                EmptyStateView(
                    symbol: "tray.fill",
                    title: "Inbox despejado",
                    message: "No hace falta llenar el espacio. Agregá algo cuando realmente aparezca."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(regularTasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
    }

    private func taskRow(_ task: LumaTask) -> some View {
        InboxTaskRow(
            task: task,
            subjectName: subjectName(for: task),
            categoryName: categoryName(for: task),
            blockerNames: blockerNames(for: task),
            unlockedTaskName: unlockedTaskName(for: task),
            onToggleCompletion: { toggleCompletion(task) },
            onSaveGrade: { saveGrade($0, for: task) },
            onEdit: { editingTask = task },
            onDelete: { delete(task) }
        )
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Todas") { selectedArea = nil }
                        .buttonStyle(SoftButtonStyle(color: selectedArea == nil ? LumaPalette.indigo : LumaPalette.secondaryInk))

                    ForEach(LifeArea.allCases) { area in
                        Button(area.title) { selectedArea = area }
                            .buttonStyle(SoftButtonStyle(color: selectedArea == area ? area.color : LumaPalette.secondaryInk))
                    }
                }
                .padding(.vertical, 2)
            }
            Toggle("Mostrar hechas", isOn: $showCompleted)
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    private var inboxTitle: some View {
        SectionTitle(
            eyebrow: "Todo entra acá",
            title: "Inbox",
            trailing: inboxCountText
        )
    }

    private var inboxCountText: String {
        let open = tasks.filter { !$0.isCompleted }.count
        guard awaitingGradeCount > 0 else { return "\(open) pendientes" }
        return "\(open) pendientes · \(awaitingGradeCount) esperando nota"
    }

    private var addButton: some View {
        Button {
            appState.quickCapturePresented = true
        } label: {
            Label("Agregar", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(LumaPalette.indigo)
    }

    private func delete(_ task: LumaTask) {
        try? calendarService.removeTaskEvent(for: task.id)
        cloudSyncService.queueTaskDeletion(task.id)
        for source in tasks where source.unlocksTaskID == task.id {
            source.unlocksTaskID = nil
            source.unlocksAnotherTask = false
        }
        modelContext.delete(task)
        try? modelContext.save()
        appState.refreshPlan()
    }

    private func toggleCompletion(_ task: LumaTask) {
        withAnimation {
            task.isCompleted ? task.restore() : task.markCompleted()
        }
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
    }

    private func saveGrade(_ grade: Double, for task: LumaTask) {
        guard (0 ... 10).contains(grade) else { return }
        task.grade = grade
        try? modelContext.save()
        appState.refreshPlan()
    }

    private func blockerNames(for task: LumaTask) -> [String] {
        TaskDependencyResolver.blockers(for: task.id, in: tasks).map(\.title)
    }

    private func unlockedTaskName(for task: LumaTask) -> String? {
        guard let targetID = task.unlocksTaskID else { return nil }
        return tasks.first { $0.id == targetID }?.title
    }

    private func subjectName(for task: LumaTask) -> String? {
        guard let id = task.academicSubjectID else { return nil }
        return subjects.first { $0.id == id }?.name
    }

    private func categoryName(for task: LumaTask) -> String? {
        guard let id = task.subjectGradeItemID else { return nil }
        return gradeItems.first { $0.id == id }?.title
    }
}

private struct InboxTaskRow: View {
    let task: LumaTask
    let subjectName: String?
    let categoryName: String?
    let blockerNames: [String]
    let unlockedTaskName: String?
    let onToggleCompletion: () -> Void
    let onSaveGrade: (Double) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isGradeEntryExpanded = false
    @State private var grade: Double?

    private var isFinishedForDisplay: Bool {
        task.isCompleted && task.academicEvaluationStatus != .awaitingGrade
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    completionButton
                    taskInformation
                    Spacer(minLength: 10)
                    rowActions
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        completionButton
                        Text(task.title)
                            .font(.headline)
                            .foregroundStyle(LumaPalette.ink)
                            .strikethrough(isFinishedForDisplay)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        rowActions
                    }
                    metadata(vertical: true)
                }
            }

            if isGradeEntryExpanded {
                Divider()
                    .opacity(0.45)
                    .padding(.vertical, 13)
                inlineGradeEntry
            }
        }
        .opacity(isFinishedForDisplay ? 0.56 : 1)
        .lumaCard(padding: 14)
    }

    private var inlineGradeEntry: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                gradeEntryExplanation
                Spacer(minLength: 12)
                gradeEntryControls
            }
            VStack(alignment: .leading, spacing: 12) {
                gradeEntryExplanation
                gradeEntryControls
            }
        }
    }

    private var gradeEntryExplanation: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Cargar calificación")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
            Text("Se actualizará automáticamente el resumen de la materia.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    private var gradeEntryControls: some View {
        HStack(spacing: 8) {
            TextField(
                "Ej. 8,5",
                value: $grade,
                format: .number.precision(.fractionLength(0 ... 2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            Text("/ 10")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
            Button("Cancelar") {
                grade = nil
                isGradeEntryExpanded = false
            }
            .buttonStyle(.borderless)
            Button("Guardar") {
                guard let grade, (0 ... 10).contains(grade) else { return }
                onSaveGrade(grade)
                self.grade = nil
                isGradeEntryExpanded = false
            }
            .buttonStyle(.borderedProminent)
            .tint(LumaPalette.indigo)
            .disabled(grade.map { !(0 ... 10).contains($0) } ?? true)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var completionButton: some View {
        Button(action: onToggleCompletion) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.isCompleted ? LumaPalette.sage : LumaPalette.secondaryInk)
        }
        .buttonStyle(.plain)
    }

    private var taskInformation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)
                .strikethrough(isFinishedForDisplay)
                .fixedSize(horizontal: false, vertical: true)
            metadata(vertical: false)
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private func metadata(vertical: Bool) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: 6) { metadataLabels }
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        } else {
            HStack(spacing: 8) { metadataLabels }
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    @ViewBuilder
    private var metadataLabels: some View {
        AreaPill(area: task.area)
        Label("\(task.estimatedMinutes) min", systemImage: "clock")
        Label(task.energy.title, systemImage: task.energy.symbol)
        if let deadline = task.deadline {
            Label(deadline.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
        }
        if let subjectName {
            Label(
                categoryName.map { "\(subjectName) · \($0)" } ?? subjectName,
                systemImage: "book.closed.fill"
            )
        }
        if let grade = task.grade {
            Label(
                "Nota \(grade.formatted(.number.precision(.fractionLength(0 ... 2)))) / 10",
                systemImage: "checkmark.seal.fill"
            )
            .foregroundStyle(grade >= 6 ? LumaPalette.sage : LumaPalette.terracotta)
        } else if task.academicEvaluationStatus == .upcomingEvaluation {
            Label("Próxima evaluación", systemImage: "calendar.badge.clock")
                .foregroundStyle(LumaPalette.indigo)
        } else if task.academicEvaluationStatus == .awaitingGrade {
            Label("Esperando nota", systemImage: "clock.badge.questionmark")
                .foregroundStyle(LumaPalette.mustard)
        } else if task.academicEvaluationStatus == .notEvaluable {
            Label("No evaluable", systemImage: "book.closed")
        }
        if !blockerNames.isEmpty, !task.isCompleted {
            Label("Bloqueada por \(blockerNames.joined(separator: ", "))", systemImage: "lock.fill")
                .foregroundStyle(LumaPalette.terracotta)
        }
        if let unlockedTaskName {
            Label("Desbloquea \(unlockedTaskName)", systemImage: "lock.open.fill")
                .foregroundStyle(LumaPalette.sage)
        }
    }

    private var rowActions: some View {
        HStack(spacing: 6) {
            if task.academicEvaluationStatus == .awaitingGrade {
                Button("Cargar nota", systemImage: "checkmark.seal") {
                    isGradeEntryExpanded = true
                }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Editar pendiente")

            Menu {
                Button("Editar", systemImage: "pencil", action: onEdit)
                if task.academicEvaluationStatus == .awaitingGrade {
                    Button("Cargar nota", systemImage: "checkmark.seal") {
                        isGradeEntryExpanded = true
                    }
                }
                Divider()
                Button(
                    task.isCompleted ? "Volver a pendientes" : "Marcar como hecha",
                    action: onToggleCompletion
                )
                if !task.isCompleted {
                    Button("Postergar un día") {
                        task.deadline = Calendar.current.date(byAdding: .day, value: 1, to: task.deadline ?? .now)
                        task.postponementCount += 1
                    }
                }
                Divider()
                Button("Eliminar", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
        }
        .fixedSize()
    }
}
