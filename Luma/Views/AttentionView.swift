import SwiftData
import SwiftUI

struct AttentionView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \LumaTask.createdAt, order: .reverse) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]
    @Query(sort: \LumaReplanRecord.createdAt, order: .reverse) private var replans: [LumaReplanRecord]

    @State private var viewModel = AttentionViewModel()

    private var awaitingGrade: [LumaTask] {
        viewModel.awaitingGrade(tasks: tasks)
    }

    private var overdue: [LumaTask] {
        viewModel.overdue(tasks: tasks)
    }

    private var blocked: [LumaTask] {
        viewModel.blocked(tasks: tasks)
    }

    private var staleWithoutDate: [LumaTask] {
        viewModel.staleWithoutDate(tasks: tasks)
    }

    private var incompleteSubjects: [(subject: AcademicSubject, configured: Double)] {
        viewModel.incompleteSubjects(subjects: subjects, gradeItems: gradeItems)
    }

    private var issueCount: Int {
        var taskIDs = Set<UUID>()
        taskIDs.formUnion(awaitingGrade.map(\.id))
        taskIDs.formUnion(overdue.map(\.id))
        taskIDs.formUnion(blocked.map(\.id))
        taskIDs.formUnion(staleWithoutDate.map(\.id))
        let cloudCount = cloudIssue == nil ? 0 : 1
        let calendarCount = calendarService.lastError == nil ? 0 : 1
        return taskIDs.count + incompleteSubjects.count + cloudCount + calendarCount
    }

    private var cloudIssue: String? {
        if case let .failed(message) = cloudSyncService.state { return message }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if issueCount == 0 {
                    EmptyStateView(
                        symbol: "checkmark.seal.fill",
                        title: "No hay nada reclamando atención",
                        message: "Tus pendientes, materias y sincronización están en orden. Podés volver al plan de hoy."
                    )
                } else {
                    taskSection(
                        eyebrow: "Seguimiento académico",
                        title: "Esperando nota",
                        tasks: awaitingGrade,
                        tint: LumaPalette.mustard,
                        emptyMessage: nil
                    )
                    taskSection(
                        eyebrow: "Fechas",
                        title: "Vencidas",
                        tasks: overdue,
                        tint: LumaPalette.terracotta,
                        emptyMessage: nil
                    )
                    taskSection(
                        eyebrow: "Dependencias",
                        title: "Bloqueadas",
                        tasks: blocked,
                        tint: LumaPalette.lavender,
                        emptyMessage: nil
                    )
                    taskSection(
                        eyebrow: "Sin lugar todavía",
                        title: "Pendientes sin fecha",
                        tasks: staleWithoutDate,
                        tint: LumaPalette.indigo,
                        emptyMessage: nil
                    )
                    academicConfigurationSection
                    integrationSection
                }

                recentActivity
            }
            .padding(30)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .navigationTitle("Atención")
        .sheet(item: Binding(
            get: { viewModel.editingTask },
            set: { viewModel.editingTask = $0 }
        )) { task in
            TaskEditorView(task: task)
                .frame(width: 720, height: 690)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) {
                SectionTitle(
                    eyebrow: "Centro de seguimiento",
                    title: "Necesita tu atención",
                    trailing: issueCount == 0 ? "Todo en orden" : "\(issueCount) para revisar"
                )
                Spacer(minLength: 16)
                Button {
                    appState.selection = .today
                } label: {
                    Label("Volver al plan", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
            }
            SectionTitle(
                eyebrow: "Centro de seguimiento",
                title: "Necesita tu atención",
                trailing: issueCount == 0 ? "Todo en orden" : "\(issueCount) para revisar"
            )
        }
    }

    @ViewBuilder
    private func taskSection(
        eyebrow: String,
        title: String,
        tasks sectionTasks: [LumaTask],
        tint: Color,
        emptyMessage: String?
    ) -> some View {
        if !sectionTasks.isEmpty || emptyMessage != nil {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    eyebrow: eyebrow,
                    title: title,
                    trailing: sectionTasks.count == 1 ? "1 tarea" : "\(sectionTasks.count) tareas"
                )
                if let emptyMessage, sectionTasks.isEmpty {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                        .lumaCard()
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(sectionTasks) { task in
                            AttentionTaskCard(
                                task: task,
                                detail: attentionDetail(for: task),
                                tint: tint,
                                onOpen: { viewModel.editingTask = task },
                                onStart: { appState.startFocus(for: task.id) },
                                onComplete: { complete(task) }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var academicConfigurationSection: some View {
        if !incompleteSubjects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    eyebrow: "Materias",
                    title: "Ponderación incompleta",
                    trailing: "\(incompleteSubjects.count) para completar"
                )
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(incompleteSubjects, id: \.subject.id) { entry in
                        Button {
                            appState.selection = .subjects
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "percent")
                                    .font(.headline)
                                    .foregroundStyle(LumaPalette.indigo)
                                    .frame(width: 38, height: 38)
                                    .background(LumaPalette.indigo.opacity(0.1), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.subject.name)
                                        .font(.headline)
                                        .foregroundStyle(LumaPalette.ink)
                                    Text(configurationText(entry.configured))
                                        .font(.caption)
                                        .foregroundStyle(LumaPalette.secondaryInk)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(LumaPalette.indigo)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .lumaCard(padding: 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var integrationSection: some View {
        if cloudIssue != nil || calendarService.lastError != nil {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    eyebrow: "Conexiones",
                    title: "Revisar sincronización",
                    trailing: nil
                )
                VStack(spacing: 10) {
                    if let cloudIssue {
                        integrationIssue(
                            title: "Supabase necesita atención",
                            detail: cloudIssue,
                            symbol: "externaldrive.badge.exclamationmark"
                        )
                    }
                    if let message = calendarService.lastError {
                        integrationIssue(
                            title: "Calendario necesita atención",
                            detail: message,
                            symbol: "calendar.badge.exclamationmark"
                        )
                    }
                }
            }
        }
    }

    private func integrationIssue(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(LumaPalette.terracotta)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(LumaPalette.ink)
                Text(detail).font(.caption).foregroundStyle(LumaPalette.secondaryInk).lineLimit(2)
            }
            Spacer()
            Button("Abrir Ajustes") { openSettings() }
                .buttonStyle(.bordered)
        }
        .lumaCard(padding: 14)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                eyebrow: "Historial",
                title: "Cambios recientes",
                trailing: "Últimos 7 días"
            )

            let activity = recentActivityItems
            if activity.isEmpty {
                Text("Cuando completes una tarea, estudies o reacomodes el día, aparecerá acá.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lumaCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activity.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(item.color)
                                .frame(width: 30, height: 30)
                                .background(item.color.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(LumaPalette.ink)
                                Text(item.date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(LumaPalette.secondaryInk)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        if index < activity.count - 1 { Divider().opacity(0.45) }
                    }
                }
                .lumaCard(padding: 14)
            }
        }
    }

    private var recentActivityItems: [AttentionActivityItem] {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let completed = tasks.compactMap { task -> AttentionActivityItem? in
            guard let date = task.completedAt, date >= start else { return nil }
            return AttentionActivityItem(
                id: "completed-\(task.id)",
                title: "Completaste \(task.title)",
                date: date,
                symbol: "checkmark",
                color: LumaPalette.sage
            )
        }
        let focused = tasks.compactMap { task -> AttentionActivityItem? in
            guard let date = task.lastFocusedAt, date >= start else { return nil }
            return AttentionActivityItem(
                id: "focus-\(task.id)",
                title: "Avanzaste \(task.focusedMinutes) min en \(task.title)",
                date: date,
                symbol: "timer",
                color: LumaPalette.indigo
            )
        }
        let replanned = replans.filter { $0.createdAt >= start }.map {
            AttentionActivityItem(
                id: "replan-\($0.id)",
                title: "Reacomodaste el plan desde \(LumaReplanSource(rawValue: $0.sourceRaw)?.title ?? "Luma")",
                date: $0.createdAt,
                symbol: "arrow.triangle.2.circlepath",
                color: LumaPalette.lavender
            )
        }
        return Array((completed + focused + replanned).sorted { $0.date > $1.date }.prefix(8))
    }

    private func attentionDetail(for task: LumaTask) -> String {
        if task.academicEvaluationStatus == .awaitingGrade {
            return "Ya está completada. Falta cargar la calificación."
        }
        if let deadline = task.deadline, deadline < .now {
            return "Venció \(deadline.formatted(date: .abbreviated, time: .omitted))."
        }
        let blockers = TaskDependencyResolver.blockers(for: task.id, in: tasks)
        if !blockers.isEmpty {
            return "Primero: \(blockers.map(\.title).joined(separator: ", "))."
        }
        return "Lleva varios días sin fecha. Asignale un lugar o archivala."
    }

    private func configurationText(_ total: Double) -> String {
        if total > 100 { return "Excede el total por \((total - 100).formatted())%." }
        return "Tiene \(total.formatted())% configurado; falta \((100 - total).formatted())%."
    }

    private func complete(_ task: LumaTask) {
        let wasCompleted = task.isCompleted
        wasCompleted ? task.restore() : task.markCompleted()
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
}

private struct AttentionTaskCard: View {
    let task: LumaTask
    let detail: String
    let tint: Color
    let onOpen: () -> Void
    let onStart: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AreaPill(area: task.area)
                Spacer()
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
            }
            Text(task.title)
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .lineLimit(3)
            HStack(spacing: 8) {
                if !task.isCompleted {
                    Button("Empezar", systemImage: "play.fill", action: onStart)
                        .buttonStyle(SoftButtonStyle(color: tint))
                }
                Button(task.isCompleted ? "Editar" : "Hecha", action: task.isCompleted ? onOpen : onComplete)
                    .buttonStyle(.borderless)
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .lumaCard(padding: 14)
    }
}

private struct AttentionActivityItem: Identifiable {
    let id: String
    let title: String
    let date: Date
    let symbol: String
    let color: Color
}
