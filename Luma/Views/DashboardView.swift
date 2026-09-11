import Combine
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \LumaProfile.createdAt) private var profiles: [LumaProfile]
    @Query(sort: \AcademicRoutine.updatedAt) private var routines: [AcademicRoutine]
    @Query(sort: \AcademicExam.date) private var exams: [AcademicExam]
    @Query(sort: \SubjectClassMeeting.updatedAt) private var classMeetings: [SubjectClassMeeting]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]

    @State private var viewModel = DashboardViewModel()
    @State private var contextViewModel = TodayContextViewModel()
    @State private var captureText = ""
    @State private var moveTasksPresented = false
    @State private var extraTimePresented = false
    @State private var reviewedTask: LumaTask?

    // La captura en lenguaje natural queda implementada, pero oculta temporalmente.
    private let showsNaturalLanguageCapture = false
    private let showsDynamicAgenda = false

    private let learningEngine = BehaviorLearningEngine()
    private let scheduler = DailyScheduler()
    private let dayChangeTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var recommendations: [PlanRecommendation] {
        viewModel.visibleRecommendations
    }

    private var rhythmProfile: UserRhythmProfile {
        viewModel.rhythmProfile
    }

    private var planner: TaskPlanner {
        let context = todayContext
        return TaskPlanner(
            rhythmProfile: appState.learningEnabled ? rhythmProfile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            preferredAreas: Set(profiles.first?.selectedAreas ?? []),
            energyPeak: profiles.first?.energyPeak,
            // `availableMinutes` is the free time the user explicitly said they have.
            // Class hours are busy blocks, not time that should be subtracted a second time.
            availableMinutes: remainingAvailableMinutes,
            planningMode: context?.planningMode ?? .realistic,
            classMeetings: classMeetings,
            subjectNames: Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0.name) }),
            weeklyAvailability: appState.weeklyAvailability,
            restCounts: context?.restCounts ?? true
        )
    }

    private var todayContext: DailyPlanningContext? {
        contextViewModel.todayContext(from: dailyContexts)
    }

    private var remainingAvailableMinutes: Int {
        appState.remainingAvailableMinutes(fallback: todayContext?.availableMinutes ?? 120)
    }

    private var classMinutesToday: Int {
        let weekday = Calendar.current.component(.weekday, from: .now)
        return classMeetings
            .filter { $0.weekday == weekday }
            .reduce(0) { $0 + max(0, $1.endMinuteOfDay - $1.startMinuteOfDay) }
    }

    private var planningInputFingerprint: String {
        let taskValues = tasks.map { task in
            [
                task.id.uuidString,
                task.title,
                task.areaRaw,
                task.dueDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "sin-entrega",
                task.deadline.map { String($0.timeIntervalSinceReferenceDate) } ?? "sin-horario",
                String(task.estimatedMinutes),
                task.energyRaw,
                task.impactRaw,
                task.academicSubjectID?.uuidString ?? "sin-materia",
                task.unlocksTaskID?.uuidString ?? "sin-dependencia",
            ].joined(separator: ":")
        }.joined(separator: "|")
        let academicValues = routines.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + exams.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + classMeetings.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + dailyContexts.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
        return "\(taskValues)#\(academicValues)#\(appState.learningEnabled)#\(appState.preferredBlockOverrideMinutes)"
    }

    private func planningBusyBlocks(for date: Date = .now) -> [BusyTimeBlock] {
        let weekday = Calendar.current.component(.weekday, from: date)
        let classes = classMeetings
            .filter { $0.weekday == weekday }
            .map {
                BusyTimeBlock(
                    title: "Clase",
                    startMinuteOfDay: $0.startMinuteOfDay,
                    endMinuteOfDay: $0.endMinuteOfDay
                )
            }
        return calendarService.busyBlocks(for: date) + classes
    }

    private var taskFingerprint: String {
        let taskValues = tasks.map(taskFingerprintValue).joined(separator: "|")
        let sessionValues = focusSessions.map { session in
            [
                session.id.uuidString,
                String(session.actualMinutes),
                String(session.completedTask),
                String(session.ignoredFromLearning),
            ].joined(separator: ":")
        }.joined(separator: "|")
        let calendarValues = calendarService.commitments.map {
            "\($0.id):\($0.start.timeIntervalSinceReferenceDate):\($0.end.timeIntervalSinceReferenceDate)"
        }.joined(separator: "|")
        let profileValue = profiles.first.map { "\($0.updatedAt.timeIntervalSinceReferenceDate)" } ?? "sin-perfil"
        let academicValues = routines.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + exams.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + classMeetings.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + subjects.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + dailyContexts.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
        return "\(taskValues)#\(sessionValues)#\(calendarValues)#\(profileValue)#\(academicValues)#\(appState.learningEnabled)#\(appState.preferredBlockOverrideMinutes)#\(remainingAvailableMinutes)"
    }

    private func taskFingerprintValue(_ task: LumaTask) -> String {
        let dueDate = task.dueDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "sin-entrega"
        let deadline = task.deadline.map { String($0.timeIntervalSinceReferenceDate) } ?? "sin-fecha"
        let subject = task.academicSubjectID?.uuidString ?? "sin-materia"
        let dependency = task.unlocksTaskID?.uuidString ?? "sin-dependencia"
        return [
            task.id.uuidString,
            String(task.updatedAt.timeIntervalSinceReferenceDate),
            task.statusRaw,
            dueDate,
            deadline,
            String(task.estimatedMinutes),
            task.energyRaw,
            task.impactRaw,
            String(task.postponementCount),
            String(task.focusedMinutes),
            subject,
            dependency,
        ].joined(separator: ":")
    }

    private var agendaItems: [AgendaDisplayItem] {
        guard let agenda = appState.dailyAgenda else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return agenda.blocks.compactMap { block in
            guard let task = byID[block.taskID], !task.isCompleted else { return nil }
            return AgendaDisplayItem(
                task: task,
                block: block,
                start: scheduler.date(on: agenda.day, minuteOfDay: block.startMinuteOfDay),
                end: scheduler.date(on: agenda.day, minuteOfDay: block.endMinuteOfDay)
            )
        }
    }

    private var timelineItems: [AgendaTimelineItem] {
        let taskEntries = agendaItems.map { AgendaTimelineItem.task($0) }
        let calendarEntries = calendarService.commitments.map { AgendaTimelineItem.commitment($0) }
        return (taskEntries + calendarEntries).sorted { $0.start < $1.start }
    }

    private var hasTimeToday: Bool {
        appState.isTodayAvailabilityConfirmed
            && (appState.dailyAgenda?.availabilityWindows.isEmpty == false)
    }

    var body: some View {
        @Bindable var appState = appState

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    timeSummary
                    if showsNaturalLanguageCapture {
                        captureBar
                    }
                    planContent(preference: $appState.energyPreference)
                    if showsDynamicAgenda { agendaSection }
                    planInsights
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, geometry.size.width < 600 ? 20 : 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
                .lumaScrollContent()
            }
            .lumaScrollSurface()
            .background(LumaHomeStyle.canvas)
        }
        .navigationTitle("Hoy")
        .task(id: taskFingerprint) {
            // Let SwiftUI paint the selected tab before touching SwiftData/EventKit.
            await Task.yield()
            guard !Task.isCancelled else { return }
            preparePlan()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { @MainActor in
                    await Task.yield()
                    preparePlan(forceExternalRefresh: true)
                }
            }
        }
        .onReceive(dayChangeTimer) { now in preparePlan(now: now) }
        .sheet(isPresented: Binding(
            get: { viewModel.agendaSettingsPresented },
            set: { viewModel.agendaSettingsPresented = $0 }
        )) {
            AgendaSettingsView()
                .frame(width: 700, height: 680)
        }
        .sheet(item: $appState.pendingReplanProposal) { proposal in
            ReplanPreviewView(
                proposal: proposal,
                tasks: tasks,
                onCancel: {
                    appState.pendingReplanProposal = nil
                    appState.pendingReplanCoachMessage = ""
                },
                onApply: { applyReplan(proposal) }
            )
        }
        .sheet(isPresented: $contextViewModel.editorPresented) {
            contextEditor
        }
        .sheet(isPresented: $moveTasksPresented) {
            MoveScheduledTasksView(
                tasks: viewModel.scheduledOutsidePlan,
                onMove: moveScheduledTaskToTomorrow
            )
        }
        .sheet(item: $reviewedTask) { task in
            TaskEditorView(task: task)
                .frame(width: 720, height: 690)
        }
    }

    private func planContent(preference: Binding<EnergyPreference>) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if viewModel.hasPreparedPresentation, !viewModel.overdueTasksNeedingReview.isEmpty {
                overdueReviewCard
            }

            if viewModel.hasPreparedPresentation, !viewModel.scheduledOutsidePlan.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .foregroundStyle(LumaPalette.mustard)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hoy no entra todo sin saturarte")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                        Text("Hay \(viewModel.scheduledOutsidePlan.count) \(viewModel.scheduledOutsidePlan.count == 1 ? "tarea" : "tareas") del calendario fuera de las prioridades. Elegí cuál mover.")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    Spacer()
                    Button("Elegir qué mover") { moveTasksPresented = true }
                        .buttonStyle(SoftButtonStyle(color: LumaPalette.mustard))
                }
                .lumaCard(padding: 14)
            }

            if viewModel.hasPreparedPresentation,
               viewModel.needsCapacityDecision,
               viewModel.scheduledOutsidePlan.isEmpty
            {
                Label(
                    "Hay una entrega próxima que necesita más trabajo del que entra en este plan. Revisá su duración o agregá tiempo para reacomodar.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(LumaPalette.terracotta)
                .lumaCard(padding: 14)
            }

            if !viewModel.hasPreparedPresentation {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Actualizando tu plan…")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .lumaCard(padding: 16)
            } else if recommendations.isEmpty {
                EmptyStateView(
                    symbol: "checkmark.seal.fill",
                    title: remainingAvailableMinutes == 0 ? "Sin tiempo pendiente por hoy" : "Sin más prioridades por ahora",
                    message: remainingAvailableMinutes == 0
                        ? "Podés sumar tiempo si cambia tu disponibilidad. Lo que ya hiciste sigue registrado."
                        : "Reacomodá el día cuando quieras elegir el siguiente avance."
                )
            } else {
                if let first = recommendations.first {
                    PriorityCard(index: 1, recommendation: first)
                        .id(first.id)
                }
                if recommendations.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("DESPUÉS, SI SEGUÍS CON TU PLAN")
                                .tracking(0.8)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(recommendations.count == 2 ? "1 prioridad" : "\(recommendations.count - 1) prioridades")
                                .fixedSize()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LumaHomeStyle.muted)
                        .padding(.bottom, 4)
                        ForEach(Array(recommendations.enumerated().dropFirst()), id: \.element.id) { index, recommendation in
                            PriorityCard(index: index + 1, recommendation: recommendation)
                        }
                    }
                }
            }

            if let rest = viewModel.restRecommendation {
                PriorityCard(index: 0, recommendation: rest)
            }

            if viewModel.hasPreparedPresentation,
               viewModel.scheduledOutsidePlan.isEmpty,
               let optional = viewModel.optionalRecommendation
            {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Si todavía te queda tiempo", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.sage)
                    Text("Es opcional: el plan de hoy ya está completo sin esto.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    OptionalPriorityCard(recommendation: optional)
                }
                .padding(.top, 2)
            }

            actionBar(preference: preference)
        }
    }

    private var overdueReviewCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Antes de reacomodar", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.terracotta)
            Text("Estas tareas pasaron su último día seguro. Confirmá si siguen vigentes antes de que Luma las arrastre.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
            ForEach(viewModel.overdueTasksNeedingReview.prefix(3)) { task in
                HStack(spacing: 10) {
                    Text(task.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .lineLimit(1)
                    Spacer()
                    Button("Mantener hoy") { keepOverdueToday(task) }
                        .buttonStyle(.borderless)
                    Button("Editar") { openTaskEditor(task) }
                        .buttonStyle(.borderless)
                    Button("Eliminar", role: .destructive) { deleteOverdueTask(task) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .lumaCard(padding: 14)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                headingTitle
                Spacer(minLength: 12)
                contextButton
            }
            VStack(alignment: .leading, spacing: 12) {
                headingTitle
                contextButton
            }
        }
    }

    private var headingTitle: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LumaHomeStyle.muted)
            Text("Un paso a la vez.")
                .font(.system(size: 32, weight: .medium))
                .tracking(-0.7)
                .foregroundStyle(LumaHomeStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextButton: some View {
        Button {
            contextViewModel.editorPresented = true
        } label: {
            Label("Tu contexto", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
        .disabled(todayContext == nil)
    }

    private var timeSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                remainingTimeLabel
                budgetBreakdown
                energyLabel
            }
            VStack(alignment: .leading, spacing: 6) {
                remainingTimeLabel
                budgetBreakdown
                energyLabel
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(LumaHomeStyle.muted)
        .accessibilityElement(children: .combine)
    }

    private var remainingTimeLabel: some View {
        Text("\(durationTitle(remainingAvailableMinutes)) disponibles")
            .fontWeight(.semibold)
            .foregroundStyle(LumaHomeStyle.ink)
    }

    private var budgetBreakdown: some View {
        let workMinutes = recommendations.reduce(0) { $0 + $1.suggestedMinutes }
        let restMinutes = viewModel.restRecommendation?.suggestedMinutes ?? 0
        return Text(viewModel.hasPreparedPresentation
            ? "\(workMinutes) min de tareas + \(restMinutes) min de descanso"
            : "Preparando tu plan…")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var energyLabel: some View {
        Text(appState.energyPreference == .tired ? "Energía baja" : (appState.energyPreference == .energized ? "Energía alta" : "Energía normal"))
    }

    private var planInsights: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("Por qué este plan") {
                Text(todayReasonSummary)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            DisclosureGroup("Un vistazo a lo que viene") {
                VStack(spacing: 16) {
                    nextExamCard
                    detectedRoutinesCard
                    upcomingRiskSection
                }
                .padding(.top, 12)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(LumaHomeStyle.muted)
        .tint(LumaHomeStyle.muted)
    }

    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(LumaPalette.indigo)
                    .padding(.top, 3)

                TextField(
                    "Decile a Luma qué querés organizar. Podés escribir varias tareas, una por línea…",
                    text: $captureText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(2 ... 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Podés separar actividades con Enter · ⌘↩ para interpretar")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                Spacer(minLength: 12)
                Button(action: openCapture) {
                    Label("Interpretar", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .lumaCard(padding: 15)
    }

    private var todayContextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tu contexto", systemImage: "person.crop.circle")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)

            if let context = todayContext {
                VStack(spacing: 0) {
                    contextSummaryRow(
                        symbol: context.energy == .tired ? "battery.25percent" : (context.energy == .energized ? "battery.100percent" : "battery.50percent"),
                        title: "Energía: \(context.energy == .tired ? "baja" : (context.energy == .energized ? "alta" : "normal"))",
                        color: context.energy == .tired ? LumaPalette.mustard : LumaPalette.sage
                    )
                    Divider().opacity(0.45)
                    contextSummaryRow(
                        symbol: "clock",
                        title: "Tiempo que te queda: \(durationTitle(remainingAvailableMinutes))",
                        color: LumaPalette.sage
                    )
                    Divider().opacity(0.45)
                    contextSummaryRow(
                        symbol: "target",
                        title: "Modo: \(context.planningMode.title.lowercased())",
                        color: LumaPalette.sage
                    )
                    Divider().opacity(0.45)
                    contextSummaryRow(
                        symbol: "cup.and.saucer.fill",
                        title: context.restCounts ? "Descanso cuenta" : "Sin descanso reservado",
                        color: context.restCounts ? LumaPalette.sage : LumaPalette.secondaryInk
                    )
                    if classMinutesToday > 0 {
                        Divider().opacity(0.45)
                        contextSummaryRow(
                            symbol: "person.3.fill",
                            title: "Clases: \(durationTitle(classMinutesToday))",
                            color: LumaPalette.indigo
                        )
                    }
                }
                .background(Color.white.opacity(0.30), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LumaPalette.indigo.opacity(0.09))
                }

                Button {
                    contextViewModel.editorPresented = true
                } label: {
                    Label("Editar contexto", systemImage: "pencil")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.indigo)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .lumaCard(padding: 16)
    }

    private var todayRightRail: some View {
        VStack(spacing: 14) {
            todayContextCard
            supplementalCards
        }
    }

    @ViewBuilder
    private var supplementalCards: some View {
        nextExamCard
        detectedRoutinesCard
        whyTodayCard
    }

    private var nextExamCard: some View {
        let exam = exams
            .filter { !$0.isArchived && $0.date >= Calendar.current.startOfDay(for: .now) }
            .min { $0.date < $1.date }

        return VStack(alignment: .leading, spacing: 14) {
            Label("Examen próximo", systemImage: "graduationcap.fill")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)

            if let exam {
                Text("\(subjectName(for: exam.subjectID)) · \(exam.date.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(2)

                examStageProgress(exam)

                Text(daysRemaining(until: exam.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.sage)
            } else {
                Text("No hay exámenes próximos.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaCard(padding: 16)
    }

    private var detectedRoutinesCard: some View {
        let active = routines
            .filter { !$0.isPaused }
            .sorted {
                if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
                return ($0.minuteOfDay ?? 1440) < ($1.minuteOfDay ?? 1440)
            }

        return VStack(alignment: .leading, spacing: 13) {
            Label("Rutinas detectadas", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)

            if active.isEmpty {
                Text("No hay rutinas activas.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            } else {
                ForEach(active.prefix(3)) { routine in
                    HStack(spacing: 10) {
                        Image(systemName: routine.activityType.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(routine.activityType == .laboratory ? LumaPalette.lavender : LumaPalette.sage)
                            .frame(width: 30, height: 30)
                            .background(
                                (routine.activityType == .laboratory ? LumaPalette.lavender : LumaPalette.sage).opacity(0.10),
                                in: Circle()
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(weekdayShortTitle(routine.weekday)): \(routine.title)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(LumaPalette.ink)
                                .lineLimit(2)
                            if let subjectID = routine.subjectID {
                                Text(subjectName(for: subjectID))
                                    .font(.caption2)
                                    .foregroundStyle(LumaPalette.secondaryInk)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaCard(padding: 16)
    }

    private var whyTodayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Por qué esto hoy", systemImage: "sparkle")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)
            Text(todayReasonSummary)
                .font(.caption.weight(.medium))
                .foregroundStyle(LumaPalette.sage)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LumaPalette.sage.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumaCard(padding: 16)
    }

    private var contextEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tu contexto de hoy")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("El plan se vuelve a calcular cuando cambiás estos datos.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 48, height: 48)
                    .background(LumaPalette.indigo.opacity(0.10), in: Circle())
            }

            if let context = todayContext {
                contextEditorControls(context)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Listo") { contextViewModel.editorPresented = false }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 620, height: 520)
        .background(LumaBackground())
    }

    private func contextEditorControls(_ context: DailyPlanningContext) -> some View {
        VStack(spacing: 0) {
            contextEditorRow(
                symbol: context.energy == .tired ? "battery.25percent" : (context.energy == .energized ? "battery.100percent" : "battery.50percent"),
                color: context.energy == .tired ? LumaPalette.mustard : LumaPalette.indigo,
                title: "Energía",
                detail: "Ajusta el tamaño y la dificultad del plan"
            ) {
                Picker("Energía", selection: Binding(
                    get: { context.energy },
                    set: { value in updateContext(context) { $0.energy = value } }
                )) {
                    Text("Baja").tag(EnergyPreference.tired)
                    Text("Normal").tag(EnergyPreference.normal)
                    Text("Alta").tag(EnergyPreference.energized)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 245)
            }

            Divider().opacity(0.45).padding(.leading, 62)

            contextEditorRow(
                symbol: "clock.fill",
                color: LumaPalette.sage,
                title: "Tiempo que te queda",
                detail: "Me quedan estos minutos para el resto de hoy"
            ) {
                HStack(spacing: 7) {
                    ForEach([30, 60, 120], id: \.self) { minutes in
                        contextChoiceButton(
                            durationTitle(minutes),
                            selected: remainingAvailableMinutes == minutes
                        ) {
                            updateRemainingTime(minutes, in: context)
                        }
                    }
                    contextChoiceButton(
                        [30, 60, 120].contains(remainingAvailableMinutes)
                            ? "Otro"
                            : durationTitle(remainingAvailableMinutes),
                        selected: ![30, 60, 120].contains(remainingAvailableMinutes)
                    ) {
                        contextViewModel.customMinutes = remainingAvailableMinutes
                        contextViewModel.customTimePresented = true
                    }
                    .popover(isPresented: $contextViewModel.customTimePresented) {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("Me quedan…")
                                .font(.headline)
                                .foregroundStyle(LumaPalette.ink)
                            Stepper(
                                "\(contextViewModel.customMinutes) min",
                                value: $contextViewModel.customMinutes,
                                in: 0 ... 600,
                                step: 15
                            )
                            Button("Usar este tiempo") {
                                updateRemainingTime(contextViewModel.customMinutes, in: context)
                                contextViewModel.customTimePresented = false
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LumaPalette.indigo)
                        }
                        .padding(18)
                        .frame(width: 270)
                    }
                }
            }

            Divider().opacity(0.45).padding(.leading, 62)

            contextEditorRow(
                symbol: "target",
                color: LumaPalette.terracotta,
                title: "Modo de planificación",
                detail: "Define cuánta exigencia querés para hoy"
            ) {
                HStack(spacing: 7) {
                    ForEach(PlanningMode.allCases) { mode in
                        contextChoiceButton(
                            mode.title,
                            selected: context.planningMode == mode
                        ) {
                            updateContext(context) { $0.planningMode = mode }
                        }
                    }
                }
            }

            Divider().opacity(0.45).padding(.leading, 62)

            contextEditorRow(
                symbol: "cup.and.saucer.fill",
                color: LumaPalette.lavender,
                title: "Descanso cuenta",
                detail: "Luma puede reservar una pausa cuando haga falta"
            ) {
                Toggle("Descanso cuenta", isOn: Binding(
                    get: { context.restCounts },
                    set: { value in updateContext(context) { $0.restCounts = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LumaPalette.indigo)
            }
        }
        .background(Color.white.opacity(0.60), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.85))
        }
        .shadow(color: LumaPalette.indigo.opacity(0.06), radius: 18, y: 8)
    }

    private func contextEditorRow<Control: View>(
        symbol: String,
        color: Color,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)
            control()
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
    }

    private func contextChoiceButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : LumaPalette.indigo)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    selected ? LumaPalette.indigo : LumaPalette.indigo.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func contextSummaryRow(symbol: String, title: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(LumaPalette.secondaryInk)
                .frame(width: 18)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(LumaPalette.secondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private func examStageProgress(_ exam: AcademicExam) -> some View {
        let completed = Set(tasks.compactMap { task -> ExamStudyStage? in
            guard task.sourceID == exam.id, task.isCompleted else { return nil }
            return task.studyStage
        })

        return HStack(spacing: 0) {
            ForEach(Array(ExamStudyStage.allCases.enumerated()), id: \.element.id) { index, stage in
                VStack(spacing: 5) {
                    Circle()
                        .fill(completed.contains(stage) ? LumaPalette.sage : Color.white.opacity(0.75))
                        .frame(width: 15, height: 15)
                        .overlay {
                            Circle().stroke(completed.contains(stage) ? LumaPalette.sage : LumaPalette.secondaryInk.opacity(0.45), lineWidth: 1.4)
                        }
                    Text(stage.shortTitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(LumaPalette.secondaryInk)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                if index < ExamStudyStage.allCases.count - 1 {
                    Rectangle()
                        .fill(LumaPalette.sage.opacity(0.38))
                        .frame(height: 2)
                        .frame(maxWidth: 17)
                        .offset(y: -7)
                }
            }
        }
    }

    private var todayReasonSummary: String {
        guard !recommendations.isEmpty else {
            return "Hoy no hay nada urgente. El plan deja espacio libre a propósito."
        }
        if recommendations.contains(where: { $0.task.academicSourceType == .examStudy }) {
            return "Hay un examen acercándose. Avanzar ahora evita concentrar todo el estudio al final."
        }
        if todayContext?.energy == .tired {
            return "Elegí avances cortos que caben en tu energía y en el tiempo disponible."
        }
        return recommendations.first?.reason ?? "Vence pronto, cabe en tu energía y evita acumulación."
    }

    private func subjectName(for id: UUID) -> String {
        subjects.first { $0.id == id }?.name ?? "Materia"
    }

    private func weekdayShortTitle(_ weekday: Int) -> String {
        ["", "Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"][max(1, min(7, weekday))]
    }

    private func daysRemaining(until date: Date) -> String {
        let days = max(0, Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: date)
        ).day ?? 0)
        return days == 1 ? "1 día restante" : "\(days) días restantes"
    }

    @ViewBuilder
    private func contextControls(_ context: DailyPlanningContext) -> some View {
        Picker("Energía", selection: Binding(
            get: { context.energy },
            set: { value in updateContext(context) { $0.energy = value } }
        )) {
            Text("Baja").tag(EnergyPreference.tired)
            Text("Normal").tag(EnergyPreference.normal)
            Text("Alta").tag(EnergyPreference.energized)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)

        Picker("Tiempo que te queda", selection: Binding(
            get: { [30, 60, 120].contains(remainingAvailableMinutes) ? remainingAvailableMinutes : -1 },
            set: { value in
                if value == -1 {
                    contextViewModel.customMinutes = remainingAvailableMinutes
                    contextViewModel.customTimePresented = true
                } else {
                    updateRemainingTime(value, in: context)
                }
            }
        )) {
            Text("30 min").tag(30)
            Text("1 h").tag(60)
            Text("2 h").tag(120)
            Text("Otro").tag(-1)
        }
        .frame(maxWidth: 210)
        .popover(isPresented: $contextViewModel.customTimePresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Me quedan…").font(.headline)
                Stepper("\(contextViewModel.customMinutes) min", value: $contextViewModel.customMinutes, in: 0 ... 600, step: 15)
                Button("Usar este tiempo") {
                    updateRemainingTime(contextViewModel.customMinutes, in: context)
                    contextViewModel.customTimePresented = false
                }
                .buttonStyle(.borderedProminent).tint(LumaPalette.indigo)
            }
            .padding(18).frame(width: 260)
        }

        Picker("Modo", selection: Binding(
            get: { context.planningMode },
            set: { value in updateContext(context) { $0.planningMode = value } }
        )) {
            ForEach(PlanningMode.allCases) { Text($0.title).tag($0) }
        }
        .frame(maxWidth: 165)

        Toggle("Descanso cuenta", isOn: Binding(
            get: { context.restCounts },
            set: { value in updateContext(context) { $0.restCounts = value } }
        ))
        .toggleStyle(.switch)
        .fixedSize()
    }

    private func openCapture() {
        let trimmed = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.quickCaptureSeed = trimmed
        appState.quickCapturePresented = true
        captureText = ""
    }

    private func updateContext(_ context: DailyPlanningContext, mutation: (DailyPlanningContext) -> Void) {
        appState.ensureDailyTimeBudget(availableMinutes: context.availableMinutes)
        mutation(context)
        context.updatedAt = .now
        appState.energyPreference = context.energy
        try? modelContext.save()
        AcademicPlanningService().materialize(
            routines: routines,
            exams: exams,
            tasks: tasks,
            dailyContext: context,
            in: modelContext
        )
        appState.replanDaily(from: tasks, planner: planner, preference: context.energy)
        appState.prepareDailyAgenda(
            from: tasks,
            planner: planner,
            scheduler: scheduler,
            force: true,
            busyBlocks: planningBusyBlocks()
        )
    }

    private func updateRemainingTime(_ minutes: Int, in context: DailyPlanningContext) {
        guard minutes != remainingAvailableMinutes else { return }
        appState.setRemainingAvailableMinutes(minutes)
        updateContext(context) { $0.availableMinutes = minutes }
    }

    private func actionBar(preference: Binding<EnergyPreference>) -> some View {
        let current = preference.wrappedValue

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                standardReplanButton()
                if current != .tired { tiredReplanButton() }
                energizedReplanButton()
            }
            VStack(alignment: .leading, spacing: 9) {
                standardReplanButton()
                if current != .tired { tiredReplanButton() }
                energizedReplanButton()
            }
        }
    }

    private func standardReplanButton() -> some View {
        Button {
            proposeReplan(
                preference: appState.energyPreference,
                message: "Reordenar el día con tu energía actual, hasta tres prioridades y el descanso reservado."
            )
        } label: {
            Label("Reacomodar mi día", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(LumaHomeButtonStyle())
    }

    private func tiredReplanButton() -> some View {
        Button {
            proposeReplan(
                preference: .tired,
                message: "No pasa nada. Bajé la carga y prioricé avances cortos que no te drenen."
            )
        } label: {
            Label("Tengo menos energía", systemImage: "battery.25percent")
        }
        .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
    }

    private func energizedReplanButton() -> some View {
        Button {
            extraTimePresented = true
        } label: {
            Label("Tengo más tiempo", systemImage: "sun.max.fill")
        }
        .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
        .popover(isPresented: $extraTimePresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("¿Cuánto tiempo más tenés?")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Text("Solo voy a sumar el siguiente avance útil.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                HStack(spacing: 8) {
                    ForEach([30, 60, 120], id: \.self) { extra in
                        Button(extra == 60 ? "+1 h" : extra == 120 ? "+2 h" : "+30 min") {
                            let current = remainingAvailableMinutes
                            extraTimePresented = false
                            proposeReplan(
                                preference: appState.energyPreference,
                                availableMinutes: min(600, current + extra),
                                message: "Sumar \(durationTitle(extra)) y agregar solo el siguiente avance útil."
                            )
                        }
                        .buttonStyle(SoftButtonStyle(color: LumaPalette.mustard))
                    }
                }
            }
            .padding(18)
            .frame(width: 330)
        }
    }

    private var upcomingRiskSection: some View {
        let risky = tasks.filter { task in
            guard !task.isCompleted else { return false }
            if task.postponementCount > 0 { return true }
            guard let deadline = task.deadline else { return false }
            return deadline < Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        }

        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                eyebrow: "Radar suave",
                title: "Lo que podría acumularse"
            )

            if risky.isEmpty {
                Text("La semana está respirando bien. No hace falta agregar más por ahora.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lumaCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(risky.prefix(3)) { task in
                        VStack(alignment: .leading, spacing: 9) {
                            AreaPill(area: task.area)
                            Text(task.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LumaPalette.ink)
                                .lineLimit(2)
                            Text(task.postponementCount > 0 ? "Postergada \(task.postponementCount) veces" : "Vence pronto")
                                .font(.caption)
                                .foregroundStyle(LumaPalette.terracotta)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .lumaCard(padding: 14)
                    }
                }
            }
        }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                eyebrow: "Agenda dinámica",
                title: "Cuándo hacerlo hoy",
                trailing: appState.dailyAgendaLabel
            )

            if !appState.isTodayAvailabilityConfirmed {
                EmptyStateView(
                    symbol: "calendar.day.timeline.left",
                    title: "¿Cuándo tenés tiempo hoy?",
                    message: "Elegí una opción rápida o armá varios bloques. No se repetirá mañana."
                )
            } else if !hasTimeToday {
                EmptyStateView(
                    symbol: "moon.zzz.fill",
                    title: "Hoy queda libre",
                    message: "No voy a programar tareas. Podés agregar tiempo si tu día cambia."
                )
            } else if agendaItems.isEmpty {
                EmptyStateView(
                    symbol: "clock.badge.checkmark",
                    title: "No hay bloques pendientes",
                    message: "Tu disponibilidad está guardada. Cuando aparezca una prioridad, Luma va a ubicarla ahí."
                )
            } else {
                agendaTimeline
            }

            if calendarService.isEnabled, !calendarService.commitments.isEmpty {
                Label(
                    "Respeté \(calendarService.commitments.count) compromisos de tu calendario",
                    systemImage: "calendar.badge.checkmark"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(LumaPalette.sage)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    agendaActionButtons
                    Spacer(minLength: 8)
                    if calendarService.isAuthorized, calendarService.isEnabled { calendarButton }
                }
                VStack(alignment: .leading, spacing: 9) {
                    agendaActionButtons
                    if calendarService.isAuthorized, calendarService.isEnabled { calendarButton }
                }
            }

            if !viewModel.calendarFeedback.isEmpty {
                Text(viewModel.calendarFeedback)
                    .font(.caption)
                    .foregroundStyle(viewModel.calendarFeedback.hasPrefix("Listo") ? LumaPalette.sage : LumaPalette.terracotta)
            }
        }
    }

    @ViewBuilder
    private var agendaActionButtons: some View {
        if appState.isTodayAvailabilityConfirmed {
            shortDayButton
            extendDayButton
            agendaSettingsButton
        } else {
            quickAvailabilityButton(30)
            quickAvailabilityButton(60)
            quickAvailabilityButton(120)
            dayFreeButton
            agendaSettingsButton
        }
    }

    private func quickAvailabilityButton(_ minutes: Int) -> some View {
        Button { setAvailableMinutes(minutes) } label: {
            Text(minutes == 60 ? "1 hora" : minutes == 120 ? "2 horas" : "30 min")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
    }

    private var dayFreeButton: some View {
        Button { setAvailableMinutes(0) } label: {
            Label("Día libre", systemImage: "moon.zzz.fill")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.lavender))
    }

    private var shortDayButton: some View {
        Button {
            proposeReplan(
                preference: appState.energyPreference,
                availableMinutes: 30,
                message: "Reducir el día a un solo avance posible de 30 minutos."
            )
        } label: {
            Label("Solo tengo 30 min", systemImage: "hourglass.bottomhalf.filled")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.lavender))
    }

    private var extendDayButton: some View {
        Button {
            let current = remainingAvailableMinutes
            proposeReplan(
                preference: appState.energyPreference,
                availableMinutes: min(600, current + 30),
                message: "Sumar 30 minutos para el siguiente avance y el descanso reservado."
            )
        } label: {
            Label("Sumar 30 min", systemImage: "plus.circle")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.mustard))
    }

    private var agendaSettingsButton: some View {
        Button { viewModel.agendaSettingsPresented = true } label: {
            Label("Ajustar disponibilidad", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
    }

    private var calendarButton: some View {
        Button { syncCalendar() } label: {
            Label("Enviar al Calendario", systemImage: "calendar.badge.plus")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.sage))
    }

    private var agendaTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { timelineMetrics }
                VStack(alignment: .leading, spacing: 8) { timelineMetrics }
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                Text("Arrastrá un bloque hacia arriba o abajo para moverlo; el resto se acomoda solo.")
            }
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)

            VStack(spacing: 0) {
                ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, entry in
                    timelineRow(entry)
                    if index < timelineItems.count - 1 {
                        let gap = max(0, Int(timelineItems[index + 1].start.timeIntervalSince(entry.end) / 60))
                        if gap >= 10 {
                            HStack(spacing: 10) {
                                Rectangle()
                                    .fill(LumaPalette.sage.opacity(0.28))
                                    .frame(width: 2, height: 22)
                                    .padding(.leading, 32)
                                Text(gap >= 30 ? "\(gap) min libres" : "Pausa de \(gap) min")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(LumaPalette.sage)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        } else {
                            Divider().opacity(0.36).padding(.vertical, 5)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var timelineMetrics: some View {
        timelineMetric(
            "Disponible",
            minutes: remainingAvailableMinutes,
            color: LumaPalette.sage
        )
        timelineMetric(
            "Planificado",
            minutes: agendaItems.reduce(0) { $0 + $1.block.durationMinutes },
            color: LumaPalette.indigo
        )
        timelineMetric(
            "Compromisos",
            minutes: calendarService.commitments.reduce(0) {
                $0 + max(0, Int($1.end.timeIntervalSince($1.start) / 60))
            },
            color: LumaPalette.lavender
        )
    }

    private func timelineMetric(_ title: String, minutes: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) · \(durationTitle(minutes))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.46), in: Capsule())
    }

    @ViewBuilder
    private func timelineRow(_ entry: AgendaTimelineItem) -> some View {
        switch entry {
        case let .task(item):
            DraggableAgendaRow(
                item: item,
                onStart: {
                    appState.startFocus(
                        for: item.task.id,
                        durationMinutes: item.block.durationMinutes
                    )
                },
                onMove: { moveAgenda(item, to: $0) }
            )
        case let .commitment(commitment):
            HStack(spacing: 14) {
                timelineTime(start: commitment.start, end: commitment.end)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LumaPalette.lavender)
                    .frame(width: 5, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(commitment.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Label("Compromiso del calendario", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private func timelineTime(start: Date, end: Date) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(start, format: .dateTime.hour().minute())
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(end, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .foregroundStyle(LumaPalette.ink)
        .frame(width: 58, alignment: .trailing)
    }

    private func agendaRow(_ item: AgendaDisplayItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                agendaTime(item)
                agendaAccent(item)
                agendaTaskInfo(item)
                Spacer(minLength: 8)
                agendaStartButton(item)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    agendaTime(item)
                    agendaAccent(item)
                    agendaTaskInfo(item)
                }
                agendaStartButton(item)
            }
        }
        .lumaCard(padding: 14)
    }

    private func agendaTime(_ item: AgendaDisplayItem) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(item.start, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(LumaPalette.ink)
            Text(item.end, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .frame(width: 66, alignment: .trailing)
    }

    private func agendaAccent(_ item: AgendaDisplayItem) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(item.task.area.color)
            .frame(width: 5, height: 44)
    }

    private func agendaTaskInfo(_ item: AgendaDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.task.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { agendaMetadata(item) }
                VStack(alignment: .leading, spacing: 5) { agendaMetadata(item) }
            }
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private func agendaMetadata(_ item: AgendaDisplayItem) -> some View {
        AreaPill(area: item.task.area)
        Text("\(item.block.durationMinutes) min")
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)
        if item.task.focusedMinutes > 0 {
            Text("\(item.task.focusedMinutes) min avanzados")
                .font(.caption)
                .foregroundStyle(LumaPalette.sage)
        }
    }

    private func agendaStartButton(_ item: AgendaDisplayItem) -> some View {
        Button {
            appState.startFocus(
                for: item.task.id,
                durationMinutes: item.block.durationMinutes
            )
        } label: {
            Label("Empezar", systemImage: "play.fill")
        }
        .buttonStyle(SoftButtonStyle(color: item.task.area.color))
    }

    private func openTaskEditor(_ task: LumaTask) {
        reviewedTask = task
    }

    private func keepOverdueToday(_ task: LumaTask) {
        let calendar = Calendar.current
        let nextHour = min(22, calendar.component(.hour, from: .now) + 1)
        task.deadline = calendar.date(
            bySettingHour: nextHour,
            minute: 0,
            second: 0,
            of: .now
        )
        task.touch()
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
    }

    private func deleteOverdueTask(_ task: LumaTask) {
        let snapshot = LumaTaskSnapshot(task: task)
        let dependentSources = tasks.filter { $0.unlocksTaskID == task.id }
        try? calendarService.removeTaskEvent(for: task.id)
        cloudSyncService.queueTaskDeletion(task.id)
        dependentSources.forEach {
            $0.unlocksTaskID = nil
            $0.unlocksAnotherTask = false
            $0.touch()
        }
        modelContext.delete(task)
        try? modelContext.save()
        appState.refreshPlan()
        appState.registerUndo(message: "Pendiente eliminado") {
            let restored = snapshot.makeTask()
            modelContext.insert(restored)
            cloudSyncService.cancelTaskDeletion(restored.id)
            dependentSources.forEach {
                $0.unlocksTaskID = restored.id
                $0.unlocksAnotherTask = true
                $0.touch()
            }
            try? modelContext.save()
            try? calendarService.syncTask(restored)
            appState.refreshPlan()
        }
    }

    private func moveScheduledTaskToTomorrow(_ task: LumaTask) {
        guard let scheduled = task.deadline,
              let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: scheduled)
        else { return }
        task.deadline = tomorrow
        task.postponementCount += 1
        task.touch()
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        viewModel.refreshPresentation(tasks: tasks, planner: planner, appState: appState)
        if viewModel.scheduledOutsidePlan.isEmpty { moveTasksPresented = false }
    }

    private func preparePlan(now: Date = .now, forceExternalRefresh: Bool = false) {
        let initialFingerprint = taskFingerprint
        if !forceExternalRefresh,
           viewModel.hasPreparedPresentation,
           appState.dashboardPreparationIsCurrent(fingerprint: initialFingerprint, now: now)
        {
            return
        }

        viewModel.rhythmProfile = learningEngine.profile(from: focusSessions, now: now)
        calendarService.refreshCommitments(for: now, force: forceExternalRefresh)
        let preparationFingerprint = taskFingerprint

        if appState.dashboardPreparationIsCurrent(
            fingerprint: preparationFingerprint,
            now: now
        ) {
            if !viewModel.hasPreparedPresentation {
                viewModel.refreshPresentation(tasks: tasks, planner: planner, appState: appState)
            }
            return
        }

        let context: DailyPlanningContext
        if let existing = todayContext {
            context = existing
        } else {
            let weekday = Calendar.current.component(.weekday, from: now)
            let savedDay = appState.weeklyAvailability.first { $0.weekday == weekday }
            context = DailyPlanningContext(
                day: now,
                energy: appState.energyPreference,
                availableMinutes: savedDay?.availableMinutes ?? 120
            )
            modelContext.insert(context)
            try? modelContext.save()
        }
        appState.ensureDailyTimeBudget(availableMinutes: context.availableMinutes, now: now)
        appState.energyPreference = context.energy
        AcademicPlanningService().materialize(
            routines: routines,
            exams: exams,
            tasks: tasks,
            dailyContext: context,
            in: modelContext,
            now: now
        )
        let update = appState.prepareDailyPlan(
            from: tasks,
            planner: planner,
            inputFingerprint: planningInputFingerprint,
            now: now
        )
        appState.prepareDailyAgenda(
            from: tasks,
            planner: planner,
            scheduler: scheduler,
            now: now,
            force: update.rolledOver,
            preferredStartMinuteOfDay: preferredAgendaStart,
            busyBlocks: planningBusyBlocks(for: now)
        )
        viewModel.refreshPresentation(tasks: tasks, planner: planner, appState: appState)
        appState.markDashboardPrepared(fingerprint: preparationFingerprint, now: now)
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks, now: now) }
        guard update.rolledOver else { return }

        if update.postponedCount > 0 {
            let noun = update.postponedCount == 1 ? "prioridad" : "prioridades"
            appState.coachMessage = "No pasa nada. Reacomodé \(update.postponedCount) \(noun) que quedó pendiente y bajé la presión del día anterior."
        } else {
            appState.coachMessage = "Nuevo día, plan nuevo. Elegí tres avances posibles sin arrastrar carga innecesaria."
        }
        try? modelContext.save()
    }

    private func proposeReplan(
        preference: EnergyPreference,
        availableMinutes: Int? = nil,
        message: String
    ) {
        presentReplan(replanProposal(
            preference: preference,
            availableMinutes: availableMinutes,
            message: message
        ))
    }

    private func replanProposal(
        preference: EnergyPreference,
        availableMinutes: Int? = nil,
        message: String
    ) -> ReplanProposal {
        ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: message,
            tasks: tasks,
            currentPlan: appState.dailyPlan,
            currentAgenda: appState.dailyAgenda,
            currentEnergy: appState.energyPreference,
            proposedEnergy: preference,
            currentAvailableMinutes: remainingAvailableMinutes,
            proposedAvailableMinutes: availableMinutes,
            timeBudget: appState.dailyTimeBudget,
            planner: planner,
            scheduler: scheduler,
            busyBlocks: planningBusyBlocks()
        )
    }

    private func presentReplan(_ proposal: ReplanProposal) {
        guard proposal.changesCurrentPlan else { return }
        appState.pendingReplanProposal = proposal
        appState.pendingReplanCoachMessage = proposal.explanation
    }

    private func applyReplan(_ proposal: ReplanProposal) {
        guard Calendar.current.isDateInToday(proposal.day) else {
            appState.pendingReplanProposal = nil
            appState.pendingReplanCoachMessage = ""
            appState.coachMessage = "Este reacomodo es de ayer. Revisemos el plan de hoy."
            return
        }
        let context = todayContext
        let previousContextEnergy = context?.energy
        let previousContextMinutes = context?.availableMinutes

        if let context {
            context.energy = proposal.afterEnergy
            if proposal.beforeAvailableMinutes != proposal.afterAvailableMinutes {
                context.availableMinutes = proposal.afterAvailableMinutes
            }
            context.updatedAt = .now
        }
        appState.applyReplan(proposal)
        appState.updateDailyPlanInputFingerprint(planningInputFingerprint)
        modelContext.insert(LumaReplanRecord(proposal: proposal))
        try? modelContext.save()
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.refreshPresentation(tasks: tasks, planner: planner, appState: appState)
        }
        appState.markDashboardPrepared(fingerprint: taskFingerprint, now: proposal.day)
        appState.coachMessage = appState.pendingReplanCoachMessage.isEmpty
            ? "Listo. Apliqué únicamente los cambios que revisaste."
            : appState.pendingReplanCoachMessage
        appState.pendingReplanProposal = nil
        appState.pendingReplanCoachMessage = ""
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        appState.registerUndo(message: "Plan reacomodado") {
            if let context {
                if let previousContextEnergy { context.energy = previousContextEnergy }
                if proposal.beforeAvailableMinutes != proposal.afterAvailableMinutes,
                   let previousContextMinutes
                {
                    context.availableMinutes = previousContextMinutes
                }
                context.updatedAt = .now
            }
            appState.restoreReplan(proposal)
            try? modelContext.save()
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.refreshPresentation(tasks: tasks, planner: planner, appState: appState)
            }
            appState.markDashboardPrepared(fingerprint: taskFingerprint, now: proposal.day)
            Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        }
    }

    private func setAvailableMinutes(_ minutes: Int) {
        if minutes != remainingAvailableMinutes {
            appState.setRemainingAvailableMinutes(minutes)
        }
        appState.configureDailyAgenda(
            availableMinutes: minutes,
            startMinuteOfDay: appState.dailyAgenda?.startMinuteOfDay ?? scheduler.defaultStartMinute(),
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            busyBlocks: planningBusyBlocks()
        )
        appState.coachMessage = minutes == 0
            ? "Listo. Hoy queda libre y no voy a empujarte tareas."
            : "Perfecto. Organicé solamente lo que entra en esos \(minutes) minutos de hoy."
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
    }

    private func syncCalendar() {
        do {
            try calendarService.syncAgenda(appState.dailyAgenda, tasks: tasks)
            viewModel.calendarFeedback = "Listo. El plan de hoy quedó en Calendario."
        } catch {
            viewModel.calendarFeedback = "No pude enviar el plan: \(error.localizedDescription)"
        }
    }

    private func moveAgenda(_ item: AgendaDisplayItem, to startMinuteOfDay: Int) {
        guard let before = appState.dailyAgenda else { return }
        appState.moveAgendaBlock(
            taskID: item.task.id,
            to: startMinuteOfDay,
            scheduler: scheduler,
            busyBlocks: planningBusyBlocks()
        )
        guard appState.dailyAgenda != before else { return }
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        appState.registerUndo(message: "Bloque movido en la agenda") {
            appState.restoreAgenda(before)
            Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        }
    }

    private func durationTitle(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return hours == 1 ? "1 h" : "\(hours) h" }
        return "\(hours) h \(remainder) min"
    }

    private var preferredAgendaStart: Int? {
        guard appState.learningEnabled, rhythmProfile.isReady,
              let hour = rhythmProfile.bestStartHour
        else { return nil }
        return hour * 60
    }
}

private struct AgendaDisplayItem: Identifiable {
    let task: LumaTask
    let block: AgendaBlockSnapshot
    let start: Date
    let end: Date

    var id: UUID { task.id }
}

private enum AgendaTimelineItem: Identifiable {
    case task(AgendaDisplayItem)
    case commitment(CalendarCommitment)

    var id: String {
        switch self {
        case let .task(item): "task-\(item.id.uuidString)"
        case let .commitment(item): "calendar-\(item.id)"
        }
    }

    var start: Date {
        switch self {
        case let .task(item): item.start
        case let .commitment(item): item.start
        }
    }

    var end: Date {
        switch self {
        case let .task(item): item.end
        case let .commitment(item): item.end
        }
    }
}

private struct DraggableAgendaRow: View {
    let item: AgendaDisplayItem
    let onStart: () -> Void
    let onMove: (Int) -> Void

    @State private var viewModel = DraggableAgendaRowViewModel()

    private var dragOffset: CGFloat {
        get { viewModel.dragOffset }
        nonmutating set { viewModel.dragOffset = newValue }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.start, format: .dateTime.hour().minute())
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(item.end, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            .foregroundStyle(LumaPalette.ink)
            .frame(width: 58, alignment: .trailing)

            RoundedRectangle(cornerRadius: 3)
                .fill(item.task.area.color)
                .frame(width: 5, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    AreaPill(area: item.task.area)
                    Text("\(item.block.durationMinutes) min")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(LumaPalette.secondaryInk.opacity(0.7))
                .help("Arrastrar para mover")

            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(item.task.area.color)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(item.task.area.color.opacity(dragOffset == 0 ? 0.03 : 0.11), in: RoundedRectangle(cornerRadius: 12))
        .offset(y: dragOffset)
        .zIndex(dragOffset == 0 ? 0 : 3)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragOffset = $0.translation.height }
                .onEnded { value in
                    guard let destination = viewModel.finishDrag(
                        translation: value.translation.height,
                        currentStart: item.block.startMinuteOfDay
                    ) else { return }
                    onMove(destination)
                }
        )
        .contextMenu {
            Button("Mover 15 min antes", systemImage: "arrow.up") {
                onMove(item.block.startMinuteOfDay - 15)
            }
            Button("Mover 15 min después", systemImage: "arrow.down") {
                onMove(item.block.startMinuteOfDay + 15)
            }
        }
    }
}

private struct PriorityCard: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    let index: Int
    let recommendation: PlanRecommendation
    @State private var viewModel = PriorityCardViewModel()
    @State private var completionSaveFailed = false
    @State private var blockExpanded = false

    private var editingTask: Bool {
        get { viewModel.editingTask }
        nonmutating set { viewModel.editingTask = newValue }
    }

    private var scheduledTimeLabel: String? {
        guard recommendation.task.academicSourceType != .rest else { return nil }
        guard let deadline = recommendation.task.deadline,
              Calendar.current.isDateInToday(deadline),
              Calendar.current.component(.hour, from: deadline) != 23
                || Calendar.current.component(.minute, from: deadline) != 59
        else { return nil }
        return deadline.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        Group {
            if index == 0 {
                restCard
            } else if index == 1 {
                featuredCard
            } else {
                compactRow
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.editingTask },
            set: { viewModel.editingTask = $0 }
        )) {
            TaskEditorView(task: recommendation.task)
                .frame(width: 720, height: 690)
        }
        .alert("No se pudo guardar el avance", isPresented: $completionSaveFailed) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text("Tu tiempo no cambió. Podés volver a intentar la acción.")
        }
    }

    private var isProgressBlock: Bool {
        recommendation.task.academicSourceType != .rest
            && recommendation.task.remainingEstimatedMinutes > recommendation.suggestedMinutes
    }

    private var completionTitle: String {
        index == 0 ? "Ya descansé" : (isProgressBlock ? "Registrar avance" : "Marcar hecha")
    }

    private var taskMetadata: String {
        let duration = isProgressBlock ? "Bloque de \(recommendation.suggestedMinutes) min" : "\(recommendation.suggestedMinutes) min"
        let scheduled = scheduledTimeLabel.map { " · \($0)" } ?? ""
        return "\(recommendation.task.area.title) · \(duration)\(scheduled)"
    }

    private var featuredCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    featureKicker
                    Circle().fill(LumaHomeStyle.accent).frame(width: 5, height: 5)
                    featureMetadata
                }
                VStack(alignment: .leading, spacing: 5) {
                    featureKicker
                    featureMetadata
                }
            }
            Text(recommendation.task.title)
                .font(.system(size: 23, weight: .medium))
                .tracking(-0.3)
                .foregroundStyle(LumaHomeStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(recommendation.reason)
                .font(.system(size: 14))
                .foregroundStyle(LumaHomeStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            fullActions
                .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(LumaHomeStyle.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LumaHomeStyle.line, lineWidth: 1)
        }
        .shadow(color: LumaHomeStyle.ink.opacity(0.025), radius: 8, y: 3)
    }

    private var featureKicker: some View {
        Text("PARA EMPEZAR")
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(LumaHomeStyle.accent)
    }

    private var featureMetadata: some View {
        Text(taskMetadata)
            .font(.system(size: 12))
            .foregroundStyle(LumaHomeStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 11) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    compactSummary
                    Spacer(minLength: 8)
                    blockDetailsButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    compactSummary
                    blockDetailsButton.padding(.leading, 37)
                }
            }
            if blockExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text(recommendation.reason)
                        .font(.system(size: 13))
                        .foregroundStyle(LumaHomeStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    fullActions
                }
                .padding(.leading, 37)
                .padding(.bottom, 3)
            }
        }
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LumaHomeStyle.line).frame(height: 1)
        }
    }

    private var compactSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", index))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(LumaHomeStyle.muted)
                .frame(width: 25)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(recommendation.task.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LumaHomeStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(taskMetadata)
                    .font(.system(size: 12))
                    .foregroundStyle(LumaHomeStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var blockDetailsButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { blockExpanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                Text(blockExpanded ? "Cerrar bloque" : "Ver bloque")
                Image(systemName: blockExpanded ? "chevron.up" : "arrow.right")
            }
        }
        .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
        .fixedSize()
        .accessibilityLabel("\(blockExpanded ? "Cerrar" : "Ver") bloque: \(recommendation.task.title)")
        .accessibilityValue(blockExpanded ? "Expandido" : "Contraído")
    }

    private var fullActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                startButton
                editButton
                completionButton
            }
            VStack(alignment: .leading, spacing: 5) {
                startButton
                HStack(spacing: 6) {
                    editButton
                    completionButton
                }
            }
        }
    }

    private var startButton: some View {
        Button {
            appState.startFocus(for: recommendation.task.id, durationMinutes: recommendation.suggestedMinutes)
        } label: {
            Label("Empezar \(recommendation.suggestedMinutes) min", systemImage: "play.fill")
        }
        .buttonStyle(LumaHomeButtonStyle(emphasis: .primary))
        .help("Abrir este bloque en Focus Room")
        .accessibilityLabel("Empezar \(recommendation.suggestedMinutes) minutos: \(recommendation.task.title)")
    }

    private var editButton: some View {
        Button("Ver detalle") { editingTask = true }
            .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
            .accessibilityLabel("Ver detalle: \(recommendation.task.title)")
    }

    private var completionButton: some View {
        Button(completionTitle, action: completeRecommendation)
            .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
            .help(isProgressBlock ? "Registrar los \(recommendation.suggestedMinutes) minutos de este bloque" : "Completar este pendiente")
            .accessibilityLabel("\(completionTitle): \(recommendation.task.title)")
    }

    private var restCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 13) {
                restSummary
                Spacer(minLength: 8)
                restActions
            }
            VStack(alignment: .leading, spacing: 12) {
                restSummary
                restActions.padding(.leading, 31)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumaHomeStyle.sage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var restSummary: some View {
        HStack(spacing: 13) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text("Tu pausa · \(recommendation.suggestedMinutes) min")
                    .font(.system(size: 14, weight: .medium))
                Text("Ya está incluida en el tiempo que te queda.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(LumaHomeStyle.sageInk)
        .layoutPriority(1)
    }

    private var restActions: some View {
        HStack(spacing: 4) {
            Button {
                appState.startFocus(for: recommendation.task.id, durationMinutes: recommendation.suggestedMinutes)
            } label: {
                HStack(spacing: 7) {
                    Text("Tomar una pausa")
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(LumaHomeStyle.sageInk)
            }
            .buttonStyle(LumaHomeButtonStyle(emphasis: .quiet))
            .fixedSize()
            .accessibilityLabel("Tomar una pausa de \(recommendation.suggestedMinutes) minutos")
            Menu {
                Button("Ya descansé", systemImage: "checkmark", action: completeRecommendation)
                Button("Ver detalle", systemImage: "pencil") { editingTask = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 28)
                    .foregroundStyle(LumaHomeStyle.sageInk)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opciones de la pausa")
            .accessibilityLabel("Opciones de la pausa")
        }
    }

    private func completeRecommendation() {
        let task = recommendation.task
        guard !task.isCompleted else { return }
        if task.academicSourceType != .rest,
           let plan = appState.dailyPlan,
           !plan.taskIDs.contains(task.id)
        {
            return
        }
        let previousPlan = appState.dailyPlan
        let previousTask = LumaTaskSnapshot(task: task)
        let eventID = UUID()
        let completedAt = Date.now
        let initialAvailableMinutes = appState.remainingAvailableMinutes()
        let isProgressBlock = task.academicSourceType != .rest
            && task.remainingEstimatedMinutes > recommendation.suggestedMinutes

        withAnimation(.easeInOut(duration: 0.2)) {
            if isProgressBlock {
                task.recordFocusSession(minutes: recommendation.suggestedMinutes, at: completedAt)
            } else {
                task.markCompleted()
            }
        }
        do {
            try modelContext.save()
        } catch {
            restoreProgress(of: task, from: previousTask)
            completionSaveFailed = true
            return
        }
        _ = appState.recordTimeSpent(
            eventID: eventID,
            minutes: recommendation.suggestedMinutes,
            initialAvailableMinutes: initialAvailableMinutes,
            now: completedAt
        )
        if task.academicSourceType == .rest {
            appState.finishRest(minutes: recommendation.suggestedMinutes)
        }
        appState.finishPlannedBlock(for: task.id)
        try? calendarService.syncTask(task)
        appState.registerUndo(message: isProgressBlock ? "Avance registrado" : "Tarea completada") {
            let currentTask = LumaTaskSnapshot(task: task)
            restoreProgress(of: task, from: previousTask)
            task.touch()
            do {
                try modelContext.save()
            } catch {
                restoreProgress(of: task, from: currentTask)
                completionSaveFailed = true
                return
            }
            _ = appState.undoTimeSpent(eventID: eventID, now: completedAt)
            appState.restoreDailyPlan(previousPlan)
            try? calendarService.syncTask(task)
        }
    }

    private func restoreProgress(of task: LumaTask, from snapshot: LumaTaskSnapshot) {
        task.status = snapshot.status
        task.completedAt = snapshot.completedAt
        task.focusedMinutes = snapshot.focusedMinutes
        task.focusSessionCount = snapshot.focusSessionCount
        task.lastFocusedAt = snapshot.lastFocusedAt
        task.updatedAt = snapshot.updatedAt
    }
}

private struct OptionalPriorityCard: View {
    @Environment(AppState.self) private var appState
    let recommendation: PlanRecommendation

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "sparkles")
                .foregroundStyle(LumaPalette.sage)
                .frame(width: 34, height: 34)
                .background(LumaPalette.sage.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(recommendation.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(2)
                Text(recommendation.reason)
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                appState.startFocus(
                    for: recommendation.task.id,
                    durationMinutes: recommendation.suggestedMinutes
                )
            } label: {
                Label("Empezar", systemImage: "play.fill")
            }
            .buttonStyle(SoftButtonStyle(color: LumaPalette.sage))
        }
        .lumaCard(padding: 14)
    }
}

private struct MoveScheduledTasksView: View {
    @Environment(\.dismiss) private var dismiss
    let tasks: [LumaTask]
    let onMove: (LumaTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("¿Qué tarea querés mover?")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Luma no va a decidirlo por vos cuando el día ya está lleno.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(tasks) { task in
                        HStack(spacing: 12) {
                            AreaPill(area: task.area)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(LumaPalette.ink)
                                    .lineLimit(2)
                                if let scheduled = task.deadline {
                                    Text(scheduled.formatted(.dateTime.hour().minute()))
                                        .font(.caption)
                                        .foregroundStyle(LumaPalette.secondaryInk)
                                }
                            }
                            Spacer()
                            Button("Mover a mañana") { onMove(task) }
                                .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                        }
                        .lumaCard(padding: 13)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Listo") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .background(LumaBackground())
    }
}
