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
    @State private var viewModel = InboxViewModel()

    private var filteredTasks: [LumaTask] {
        viewModel.filteredTasks(from: tasks)
    }

    private var awaitingGradeTasks: [LumaTask] {
        viewModel.awaitingGradeTasks(from: tasks)
    }

    private var regularTasks: [LumaTask] {
        viewModel.regularTasks(from: tasks)
    }

    var body: some View {
        HStack(spacing: 0) {
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
                    if viewModel.selectedSmartFilter == .all || viewModel.selectedSmartFilter == .evaluations {
                        awaitingGradesSection
                        Divider().opacity(0.45)
                    }
                    regularTasksSection
                }
                .padding(30)
                .frame(maxWidth: 980, alignment: .leading)
            }

            if let selectedTask = viewModel.selectedTask {
                Divider().opacity(0.55)
                TaskDetailPanel(
                    task: selectedTask,
                    subjectName: subjectName(for: selectedTask),
                    categoryName: categoryName(for: selectedTask),
                    blockers: blockerNames(for: selectedTask),
                    unlockedTaskName: unlockedTaskName(for: selectedTask),
                    isCalendarSynced: calendarService.isTaskSynced(selectedTask.id),
                    onClose: { viewModel.selectedTask = nil },
                    onEdit: { viewModel.editingTask = selectedTask },
                    onStart: { appState.startFocus(for: selectedTask.id) },
                    onToggleCompletion: { toggleCompletion(selectedTask) }
                )
                .frame(width: 350)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.selectedTask?.id)
        .navigationTitle("Inbox")
        .sheet(isPresented: Binding(
            get: { viewModel.editingTask != nil },
            set: { if !$0 { viewModel.editingTask = nil } }
        )) {
            if let editingTask = viewModel.editingTask {
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
            onOpenDetail: { viewModel.selectedTask = task },
            onEdit: { viewModel.editingTask = task },
            onPostpone: { postpone(task) },
            onDelete: { delete(task) }
        )
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SmartTaskFilter.allCases) { filter in
                        Button {
                            viewModel.selectedSmartFilter = filter
                            if filter == .completed { viewModel.showCompleted = true }
                        } label: {
                            Label(filter.title, systemImage: filter.symbol)
                        }
                        .buttonStyle(SoftButtonStyle(
                            color: viewModel.selectedSmartFilter == filter
                                ? filter.color
                                : LumaPalette.secondaryInk
                        ))
                    }
                }
                .padding(.vertical, 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Todas las áreas") { viewModel.selectedArea = nil }
                        .buttonStyle(SoftButtonStyle(color: viewModel.selectedArea == nil ? LumaPalette.indigo : LumaPalette.secondaryInk))

                    ForEach(LifeArea.allCases) { area in
                        Button(area.title) { viewModel.selectedArea = area }
                            .buttonStyle(SoftButtonStyle(color: viewModel.selectedArea == area ? area.color : LumaPalette.secondaryInk))
                    }
                }
                .padding(.vertical, 2)
            }
            Toggle("Mostrar hechas", isOn: Binding(
                get: { viewModel.showCompleted },
                set: { viewModel.showCompleted = $0 }
            ))
                .toggleStyle(.switch)
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .disabled(viewModel.selectedSmartFilter == .completed)
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
        viewModel.inboxCountText(tasks: tasks)
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
        let snapshot = LumaTaskSnapshot(task: task)
        let dependentSources = tasks.filter { $0.unlocksTaskID == task.id }
        try? calendarService.removeTaskEvent(for: task.id)
        cloudSyncService.queueTaskDeletion(task.id)
        for source in dependentSources {
            source.unlocksTaskID = nil
            source.unlocksAnotherTask = false
            source.touch()
        }
        if viewModel.selectedTask?.id == task.id { viewModel.selectedTask = nil }
        modelContext.delete(task)
        try? modelContext.save()
        appState.refreshPlan()
        appState.registerUndo(message: "Pendiente eliminado") {
            let restored = snapshot.makeTask()
            modelContext.insert(restored)
            cloudSyncService.cancelTaskDeletion(restored.id)
            for source in dependentSources {
                source.unlocksTaskID = restored.id
                source.unlocksAnotherTask = true
                source.touch()
            }
            try? modelContext.save()
            try? calendarService.syncTask(restored)
            appState.refreshPlan()
            viewModel.selectedTask = restored
        }
    }

    private func toggleCompletion(_ task: LumaTask) {
        let wasCompleted = task.isCompleted
        withAnimation {
            wasCompleted ? task.restore() : task.markCompleted()
        }
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        appState.registerUndo(message: wasCompleted ? "La tarea volvió a pendientes" : "Tarea completada") {
            wasCompleted ? task.markCompleted() : task.restore()
            try? modelContext.save()
            try? calendarService.syncTask(task)
            appState.refreshPlan()
        }
    }

    private func saveGrade(_ grade: Double, for task: LumaTask) {
        guard (0 ... 10).contains(grade) else { return }
        task.grade = grade
        task.touch()
        try? modelContext.save()
        appState.refreshPlan()
    }

    private func postpone(_ task: LumaTask) {
        let previousDeadline = task.deadline
        let previousCount = task.postponementCount
        task.deadline = Calendar.current.date(byAdding: .day, value: 1, to: task.deadline ?? .now)
        task.postponementCount += 1
        task.touch()
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        appState.registerUndo(message: "Tarea postergada un día") {
            task.deadline = previousDeadline
            task.postponementCount = previousCount
            task.touch()
            try? modelContext.save()
            try? calendarService.syncTask(task)
            appState.refreshPlan()
        }
    }

    private func blockerNames(for task: LumaTask) -> [String] {
        viewModel.blockerNames(for: task, tasks: tasks)
    }

    private func unlockedTaskName(for task: LumaTask) -> String? {
        viewModel.unlockedTaskName(for: task, tasks: tasks)
    }

    private func subjectName(for task: LumaTask) -> String? {
        viewModel.subjectName(for: task, subjects: subjects)
    }

    private func categoryName(for task: LumaTask) -> String? {
        viewModel.categoryName(for: task, gradeItems: gradeItems)
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
    let onOpenDetail: () -> Void
    let onEdit: () -> Void
    let onPostpone: () -> Void
    let onDelete: () -> Void

    @State private var viewModel = InboxTaskRowViewModel()

    private var isGradeEntryExpanded: Bool {
        get { viewModel.isGradeEntryExpanded }
        nonmutating set { viewModel.isGradeEntryExpanded = newValue }
    }
    private var grade: Double? {
        get { viewModel.grade }
        nonmutating set { viewModel.grade = newValue }
    }

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
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
                value: Binding(
                    get: { viewModel.grade },
                    set: { viewModel.grade = $0 }
                ),
                format: .number.precision(.fractionLength(0 ... 2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            Text("/ 10")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
            Button("Cancelar") {
                viewModel.cancelGradeEntry()
            }
            .buttonStyle(.borderless)
            Button("Guardar") {
                guard let grade = viewModel.submittedGrade() else { return }
                onSaveGrade(grade)
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
                    Button("Postergar un día", action: onPostpone)
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

enum SmartTaskFilter: String, CaseIterable, Identifiable {
    case all
    case week
    case evaluations
    case quick
    case lowEnergy
    case blocked
    case noDate
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Todo"
        case .week: "Esta semana"
        case .evaluations: "Evaluaciones"
        case .quick: "Tareas rápidas"
        case .lowEnergy: "Poca energía"
        case .blocked: "Bloqueadas"
        case .noDate: "Sin fecha"
        case .completed: "Hechas"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .week: "calendar"
        case .evaluations: "graduationcap"
        case .quick: "bolt.fill"
        case .lowEnergy: "battery.25percent"
        case .blocked: "lock.fill"
        case .noDate: "calendar.badge.questionmark"
        case .completed: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .all: LumaPalette.indigo
        case .week, .evaluations: LumaPalette.mustard
        case .quick: LumaPalette.sage
        case .lowEnergy: LumaPalette.lavender
        case .blocked: LumaPalette.terracotta
        case .noDate, .completed: LumaPalette.secondaryInk
        }
    }

    func matches(_ task: LumaTask, in tasks: [LumaTask], now: Date = .now) -> Bool {
        switch self {
        case .all:
            return true
        case .week:
            guard !task.isCompleted, let deadline = task.deadline else { return false }
            let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
            return deadline >= Calendar.current.startOfDay(for: now) && deadline <= end
        case .evaluations:
            return task.academicEvaluationStatus == .upcomingEvaluation
                || task.academicEvaluationStatus == .awaitingGrade
        case .quick:
            return !task.isCompleted && task.remainingEstimatedMinutes <= 30
        case .lowEnergy:
            return !task.isCompleted && task.energy == .low
        case .blocked:
            return !task.isCompleted && TaskDependencyResolver.isBlocked(task, in: tasks)
        case .noDate:
            return !task.isCompleted && task.deadline == nil
        case .completed:
            return task.isCompleted
        }
    }
}

private struct TaskDetailPanel: View {
    let task: LumaTask
    let subjectName: String?
    let categoryName: String?
    let blockers: [String]
    let unlockedTaskName: String?
    let isCalendarSynced: Bool
    let onClose: () -> Void
    let onEdit: () -> Void
    let onStart: () -> Void
    let onToggleCompletion: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Detalle")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaPalette.secondaryInk)
            }
            .padding(18)

            Divider().opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        AreaPill(area: task.area)
                        Text(task.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(statusTitle, systemImage: statusSymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }

                    actionButtons

                    detailSection("Planificación") {
                        detailRow("Duración", "\(task.estimatedMinutes) min", "timer")
                        detailRow("Energía", task.energy.title, task.energy.symbol)
                        detailRow("Impacto", task.impact.title, "chart.bar.fill")
                        detailRow(
                            "Fecha",
                            task.deadline?.formatted(date: .abbreviated, time: .omitted) ?? "Sin fecha",
                            "calendar"
                        )
                    }

                    if task.focusedMinutes > 0 || task.focusSessionCount > 0 {
                        detailSection("Progreso") {
                            ProgressView(
                                value: Double(min(task.focusedMinutes, task.estimatedMinutes)),
                                total: Double(max(1, task.estimatedMinutes))
                            )
                            .tint(LumaPalette.sage)
                            Text("\(task.focusedMinutes) min en \(task.focusSessionCount) sesiones · quedan aproximadamente \(task.remainingEstimatedMinutes) min")
                                .font(.caption)
                                .foregroundStyle(LumaPalette.secondaryInk)
                        }
                    }

                    if subjectName != nil {
                        detailSection("Evaluación académica") {
                            detailRow("Materia", subjectName ?? "Sin materia", "book.closed.fill")
                            if let categoryName {
                                detailRow("Categoría", categoryName, "percent")
                            }
                            detailRow(
                                "Calificación",
                                task.grade.map { "\($0.formatted(.number.precision(.fractionLength(0 ... 2)))) / 10" }
                                    ?? task.academicEvaluationStatus?.title
                                    ?? "No evaluable",
                                task.academicEvaluationStatus?.symbol ?? "book.closed"
                            )
                        }
                    }

                    if !blockers.isEmpty || unlockedTaskName != nil {
                        detailSection("Dependencias") {
                            if !blockers.isEmpty {
                                Label("Bloqueada por \(blockers.joined(separator: ", "))", systemImage: "lock.fill")
                                    .foregroundStyle(LumaPalette.terracotta)
                            }
                            if let unlockedTaskName {
                                Label("Desbloquea \(unlockedTaskName)", systemImage: "lock.open.fill")
                                    .foregroundStyle(LumaPalette.sage)
                            }
                        }
                    }

                    if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        detailSection("Notas") {
                            Text(task.notes)
                                .font(.subheadline)
                                .foregroundStyle(LumaPalette.ink)
                                .textSelection(.enabled)
                        }
                    }

                    detailSection("Actividad") {
                        detailRow("Creada", task.createdAt.formatted(date: .abbreviated, time: .shortened), "plus.circle")
                        if let lastFocusedAt = task.lastFocusedAt {
                            detailRow("Último avance", lastFocusedAt.formatted(date: .abbreviated, time: .shortened), "timer")
                        }
                        if let completedAt = task.completedAt {
                            detailRow("Completada", completedAt.formatted(date: .abbreviated, time: .shortened), "checkmark.circle")
                        }
                        if task.postponementCount > 0 {
                            detailRow("Postergaciones", "\(task.postponementCount)", "arrow.right")
                        }
                        detailRow(
                            "Calendario",
                            isCalendarSynced ? "Sincronizada" : "Sin evento asociado",
                            isCalendarSynced ? "calendar.badge.checkmark" : "calendar.badge.minus"
                        )
                    }
                }
                .padding(18)
            }
        }
        .background(Color.white.opacity(0.24))
    }

    private var actionButtons: some View {
        VStack(spacing: 9) {
            Button(action: onEdit) {
                Label("Editar pendiente", systemImage: "pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LumaPalette.indigo)

            HStack(spacing: 8) {
                if !task.isCompleted {
                    Button("Empezar", systemImage: "play.fill", action: onStart)
                        .buttonStyle(.bordered)
                }
                Button(
                    task.isCompleted ? "Volver" : "Marcar hecha",
                    systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark",
                    action: onToggleCompletion
                )
                .buttonStyle(.bordered)
            }
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(LumaPalette.sage)
            content()
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private func detailRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(LumaPalette.indigo)
                .frame(width: 17)
            Text(title)
                .foregroundStyle(LumaPalette.secondaryInk)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(LumaPalette.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    private var statusTitle: String {
        if !blockers.isEmpty, !task.isCompleted { return "Bloqueada" }
        if let evaluation = task.academicEvaluationStatus { return evaluation.title }
        return task.isCompleted ? "Completada" : "Pendiente"
    }

    private var statusSymbol: String {
        if !blockers.isEmpty, !task.isCompleted { return "lock.fill" }
        if let evaluation = task.academicEvaluationStatus { return evaluation.symbol }
        return task.isCompleted ? "checkmark.circle.fill" : "circle"
    }

    private var statusColor: Color {
        if !blockers.isEmpty, !task.isCompleted { return LumaPalette.terracotta }
        if task.isCompleted { return LumaPalette.sage }
        if task.academicEvaluationStatus == .awaitingGrade { return LumaPalette.mustard }
        return LumaPalette.indigo
    }
}
