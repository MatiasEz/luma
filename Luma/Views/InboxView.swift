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

    private var filteredTasks: [LumaTask] {
        tasks.filter { task in
            (showCompleted || !task.isCompleted) && (selectedArea == nil || task.area == selectedArea)
        }
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

                if filteredTasks.isEmpty {
                    EmptyStateView(
                        symbol: "tray.fill",
                        title: "Inbox despejado",
                        message: "No hace falta llenar el espacio. Agregá algo cuando realmente aparezca."
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredTasks) { task in
                            InboxTaskRow(
                                task: task,
                                subjectName: subjectName(for: task),
                                categoryName: categoryName(for: task),
                                blockerNames: blockerNames(for: task),
                                unlockedTaskName: unlockedTaskName(for: task),
                                onToggleCompletion: { toggleCompletion(task) },
                                onEdit: { editingTask = task },
                                onDelete: { delete(task) }
                            )
                        }
                    }
                }
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
            trailing: "\(tasks.filter { !$0.isCompleted }.count) pendientes"
        )
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
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
                        .strikethrough(task.isCompleted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    rowActions
                }
                metadata(vertical: true)
            }
        }
        .opacity(task.isCompleted ? 0.56 : 1)
        .lumaCard(padding: 14)
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
                .strikethrough(task.isCompleted)
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
        } else if task.academicEvaluationStatus == .pendingGrade {
            Label("Nota pendiente", systemImage: "clock.badge.questionmark")
                .foregroundStyle(LumaPalette.indigo)
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
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Editar pendiente")

            Menu {
                Button("Editar", systemImage: "pencil", action: onEdit)
                if task.academicEvaluationStatus == .pendingGrade {
                    Button("Cargar nota", systemImage: "checkmark.seal", action: onEdit)
                }
                Divider()
                Button(
                    task.isCompleted ? "Volver a pendientes" : "Marcar como hecha",
                    action: onToggleCompletion
                )
                Button("Postergar un día") {
                    task.deadline = Calendar.current.date(byAdding: .day, value: 1, to: task.deadline ?? .now)
                    task.postponementCount += 1
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
