import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt, order: .reverse) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @State private var viewModel = InboxViewModel()

    private var filteredTasks: [LumaTask] {
        viewModel.filteredTasks(from: tasks)
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
                    regularTasksSection
                }
                .padding(30)
                .lumaScrollContent()
            }
            .lumaScrollSurface()

            if let selectedTask = viewModel.selectedTask {
                Divider().opacity(0.55)
                TaskDetailPanel(
                    task: selectedTask,
                    subjectName: subjectName(for: selectedTask),
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

    private var regularTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                eyebrow: taskSectionEyebrow,
                title: taskSectionTitle,
                trailing: "\(regularTasks.count) tareas"
            )

            if regularTasks.isEmpty {
                EmptyStateView(
                    symbol: "tray.fill",
                    title: emptyStateTitle,
                    message: emptyStateMessage
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

    private var taskSectionEyebrow: String {
        if viewModel.selectedSmartFilter == .completed { return "Historial" }
        if viewModel.showCompleted { return "Tareas" }
        return "Por hacer"
    }

    private var taskSectionTitle: String {
        if viewModel.selectedSmartFilter == .completed { return "Completadas" }
        if viewModel.showCompleted { return "Resultados" }
        return "Pendientes"
    }

    private var emptyStateTitle: String {
        viewModel.selectedSmartFilter == .completed
            ? "No hay tareas completadas"
            : "No hay tareas con estos filtros"
    }

    private var emptyStateMessage: String {
        viewModel.hasCustomFilters
            ? "Probá cambiando o limpiando los filtros."
            : "Cuando agregues una nueva tarea, aparecerá acá."
    }

    private func taskRow(_ task: LumaTask) -> some View {
        InboxTaskRow(
            task: task,
            subjectName: subjectName(for: task),
            blockerNames: blockerNames(for: task),
            unlockedTaskName: unlockedTaskName(for: task),
            onToggleCompletion: { toggleCompletion(task) },
            onOpenDetail: { viewModel.selectedTask = task },
            onEdit: { viewModel.editingTask = task },
            onPostpone: { postpone(task) },
            onDelete: { delete(task) }
        )
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Filtrar tareas", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
                if viewModel.hasCustomFilters {
                    Button("Limpiar filtros") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.resetFilters()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.indigo)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Text("MOSTRAR")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(LumaPalette.sage)
                        .padding(.trailing, 3)

                    ForEach(primarySmartFilters) { filter in
                        smartFilterButton(filter)
                    }

                    moreFiltersMenu

                    Divider()
                        .frame(height: 22)
                        .padding(.horizontal, 3)

                    Toggle("Incluir hechas", isOn: Binding(
                        get: {
                            viewModel.selectedSmartFilter == .completed
                                ? true
                                : viewModel.showCompleted
                        },
                        set: {
                            guard viewModel.selectedSmartFilter != .completed else { return }
                            viewModel.showCompleted = $0
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .disabled(viewModel.selectedSmartFilter == .completed)
                }
                .padding(.vertical, 2)
            }

            Divider().opacity(0.45)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Text("ÁREA")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(LumaPalette.sage)
                        .padding(.trailing, 3)

                    Button { viewModel.selectedArea = nil } label: {
                        InboxFilterChip(
                            title: "Todas",
                            symbol: "square.grid.2x2",
                            tint: LumaPalette.indigo,
                            isSelected: viewModel.selectedArea == nil
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(LifeArea.allCases) { area in
                        Button { viewModel.selectedArea = area } label: {
                            InboxFilterChip(
                                title: area.title,
                                symbol: area.symbol,
                                tint: area.color,
                                isSelected: viewModel.selectedArea == area
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.30), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        }
    }

    private var primarySmartFilters: [SmartTaskFilter] {
        [.all, .week, .evaluations, .quick]
    }

    private var secondarySmartFilters: [SmartTaskFilter] {
        [.lowEnergy, .blocked, .noDate, .completed]
    }

    private var selectedSecondaryFilter: SmartTaskFilter? {
        secondarySmartFilters.contains(viewModel.selectedSmartFilter)
            ? viewModel.selectedSmartFilter
            : nil
    }

    private func smartFilterButton(_ filter: SmartTaskFilter) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.select(filter)
            }
        } label: {
            InboxFilterChip(
                title: filter.title,
                symbol: filter.symbol,
                tint: filter.color,
                isSelected: viewModel.selectedSmartFilter == filter
            )
        }
        .buttonStyle(.plain)
    }

    private var moreFiltersMenu: some View {
        Menu {
            ForEach(secondarySmartFilters) { filter in
                Button {
                    viewModel.select(filter)
                } label: {
                    Label(filter.title, systemImage: filter.symbol)
                }
            }
        } label: {
            InboxFilterChip(
                title: selectedSecondaryFilter?.title ?? "Más",
                symbol: selectedSecondaryFilter?.symbol ?? "ellipsis.circle",
                tint: selectedSecondaryFilter?.color ?? LumaPalette.secondaryInk,
                isSelected: selectedSecondaryFilter != nil,
                showsChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

}

private struct InboxTaskRow: View {
    let task: LumaTask
    let subjectName: String?
    let blockerNames: [String]
    let unlockedTaskName: String?
    let onToggleCompletion: () -> Void
    let onOpenDetail: () -> Void
    let onEdit: () -> Void
    let onPostpone: () -> Void
    let onDelete: () -> Void

    private var isFinishedForDisplay: Bool {
        task.isCompleted
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
        }
        .opacity(isFinishedForDisplay ? 0.56 : 1)
        .lumaCard(padding: 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
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
        if let dueDate = task.dueDate {
            Label("Entrega \(dueDate.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar.badge.exclamationmark")
        } else if let deadline = task.deadline {
            Label(deadline.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
        }
        if let subjectName {
            Label(subjectName, systemImage: "book.closed.fill")
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
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Editar pendiente")

            Menu {
                Button("Editar", systemImage: "pencil", action: onEdit)
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

private struct InboxFilterChip: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    var showsChevron = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.72)
            }
        }
        .foregroundStyle(isSelected ? tint : LumaPalette.secondaryInk)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            isSelected ? tint.opacity(0.13) : Color.white.opacity(0.26),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    isSelected ? tint.opacity(0.26) : Color.white.opacity(0.36),
                    lineWidth: 1
                )
        }
        .contentShape(Capsule())
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

    func matches(
        _ task: LumaTask,
        in tasks: [LumaTask],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .week:
            return relevantDate(for: task, now: now, calendar: calendar) != nil
        case .evaluations:
            return task.area == .university
                && (task.impact == .grade
                    || task.subjectGradeItemID != nil
                    || task.academicSourceType == .examStudy)
        case .quick:
            let minutes = task.isCompleted ? task.estimatedMinutes : task.remainingEstimatedMinutes
            return minutes <= 30
        case .lowEnergy:
            return task.energy == .low
        case .blocked:
            return !task.isCompleted && TaskDependencyResolver.isBlocked(task, in: tasks)
        case .noDate:
            return task.dueDate == nil && task.deadline == nil
        case .completed:
            return true
        }
    }

    func relevantDate(
        for task: LumaTask,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date? {
        guard self == .week else { return task.dueDate ?? task.deadline }

        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        return [task.deadline, task.dueDate]
            .compactMap { $0 }
            .filter(week.contains)
            .min()
    }
}

struct TaskDetailPanel: View {
    let task: LumaTask
    let subjectName: String?
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
                        if let dueDate = task.dueDate {
                            detailRow("Entrega", dueDate.formatted(date: .abbreviated, time: .omitted), "calendar.badge.exclamationmark")
                        }
                        if let deadline = task.deadline {
                            detailRow("Programada", deadline.formatted(date: .abbreviated, time: .omitted), "calendar")
                            detailRow("Inicio", taskTimeLabel(deadline), "clock")
                        } else if task.dueDate == nil {
                            detailRow("Calendario", "Sin programar", "calendar")
                        }
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
                        detailSection("Materia") {
                            detailRow("Materia", subjectName ?? "Sin materia", "book.closed.fill")
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
                        detailSection("Descripción") {
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
                .lumaScrollContent()
            }
            .lumaScrollSurface()
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
        return task.isCompleted ? "Completada" : "Pendiente"
    }

    private func taskTimeLabel(_ deadline: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: deadline)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        if hour == 23, minute == 59 { return "Sin hora" }
        return String(format: "%02d:%02d", hour, minute)
    }

    private var statusSymbol: String {
        if !blockers.isEmpty, !task.isCompleted { return "lock.fill" }
        return task.isCompleted ? "checkmark.circle.fill" : "circle"
    }

    private var statusColor: Color {
        if !blockers.isEmpty, !task.isCompleted { return LumaPalette.terracotta }
        if task.isCompleted { return LumaPalette.sage }
        return LumaPalette.indigo
    }
}
