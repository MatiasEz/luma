import Foundation
import Observation

struct DailyPlanSnapshot: Codable, Equatable {
    var day: Date
    var taskIDs: [UUID]
    var energyPreference: EnergyPreference
}

struct DailyPlanUpdate: Equatable {
    var created = false
    var rolledOver = false
    var postponedCount = 0
}

enum NavigationItem: String, CaseIterable, Identifiable {
    case today
    case inbox
    case attention
    case week
    case subjects
    case balance
    case insights
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Hoy"
        case .inbox: "Inbox"
        case .attention: "Atención"
        case .week: "Semana"
        case .subjects: "Materias"
        case .balance: "Balance"
        case .insights: "Tu ritmo"
        case .focus: "Focus Room"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sparkles"
        case .inbox: "tray.full.fill"
        case .attention: "bell.badge.fill"
        case .week: "calendar"
        case .subjects: "books.vertical.fill"
        case .balance: "circle.hexagongrid.fill"
        case .insights: "brain.head.profile"
        case .focus: "moon.zzz.fill"
        }
    }
}

@MainActor
@Observable
final class AppState {
    private static let dailyPlanKey = "lumaDailyPlanSnapshot"
    private static let dailyAgendaKey = "lumaDailyAgendaSnapshot"
    private static let learningEnabledKey = "lumaLearningEnabled"
    private static let preferredBlockOverrideKey = "lumaPreferredBlockOverride"
    private static let onboardingCompletedKey = "lumaOnboardingCompleted"
    private static let weeklyAvailabilityKey = "lumaWeeklyAvailability"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var undoHandler: (() -> Void)?
    @ObservationIgnored private var undoDismissTask: Task<Void, Never>?

    var selection: NavigationItem? = .today
    var energyPreference: EnergyPreference = .normal
    var quickCapturePresented = false
    var assistantPresented = false
    var pendingReplanProposal: ReplanProposal?
    var pendingReplanCoachMessage = ""
    var planRevision = 0
    var focusTaskID: UUID?
    var focusDurationMinutes: Int?
    var undoMessage: String?
    var onboardingCompleted = false {
        didSet { defaults.set(onboardingCompleted, forKey: Self.onboardingCompletedKey) }
    }
    var weeklyAvailability: [DayAvailability] = DayAvailability.standardWeek {
        didSet {
            if let data = try? JSONEncoder().encode(weeklyAvailability) {
                defaults.set(data, forKey: Self.weeklyAvailabilityKey)
            }
            refreshPlan()
        }
    }
    var learningEnabled = true {
        didSet {
            defaults.set(learningEnabled, forKey: Self.learningEnabledKey)
            refreshPlan()
        }
    }

    var preferredBlockOverrideMinutes = 0 {
        didSet {
            defaults.set(preferredBlockOverrideMinutes, forKey: Self.preferredBlockOverrideKey)
            refreshPlan()
        }
    }

    var coachMessage = "Tranqui. No necesitamos resolver todo hoy; empecemos por tres avances que realmente mueven la semana."
    private(set) var dailyPlan: DailyPlanSnapshot?
    private(set) var dailyAgenda: DailyAgendaSnapshot?

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: Date = .now
    ) {
        self.defaults = defaults
        self.calendar = calendar
        learningEnabled = defaults.object(forKey: Self.learningEnabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.learningEnabledKey)
        preferredBlockOverrideMinutes = defaults.integer(forKey: Self.preferredBlockOverrideKey)
        onboardingCompleted = defaults.bool(forKey: Self.onboardingCompletedKey)
        if let data = defaults.data(forKey: Self.weeklyAvailabilityKey),
           let saved = try? JSONDecoder().decode([DayAvailability].self, from: data),
           saved.count == 7
        {
            weeklyAvailability = saved
        }

        if let data = defaults.data(forKey: Self.dailyPlanKey),
           let snapshot = try? JSONDecoder().decode(DailyPlanSnapshot.self, from: data)
        {
            dailyPlan = snapshot
            if calendar.isDate(snapshot.day, inSameDayAs: now) {
                energyPreference = snapshot.energyPreference
            }
        }

        if let data = defaults.data(forKey: Self.dailyAgendaKey),
           let snapshot = try? JSONDecoder().decode(DailyAgendaSnapshot.self, from: data)
        {
            dailyAgenda = snapshot
        }
    }

    func refreshPlan() {
        planRevision += 1
    }

    @discardableResult
    func prepareDailyPlan(
        from tasks: [LumaTask],
        planner: TaskPlanner,
        now: Date = .now
    ) -> DailyPlanUpdate {
        let pending = tasks.filter { !$0.isCompleted }
        let today = calendar.startOfDay(for: now)

        if let dailyPlan, calendar.isDate(dailyPlan.day, inSameDayAs: today) {
            if dailyPlan.taskIDs.isEmpty, !pending.isEmpty {
                let ids = planner.recommendations(
                    from: pending,
                    now: now,
                    preference: energyPreference
                ).map(\.task.id)
                savePlan(day: today, taskIDs: ids, preference: energyPreference)
                refreshPlan()
                return DailyPlanUpdate(created: true)
            }
            return DailyPlanUpdate()
        }

        let previousIDs = Set(dailyPlan?.taskIDs ?? [])
        let postponed = pending.filter { previousIDs.contains($0.id) }
        postponed.forEach {
            $0.postponementCount += 1
            $0.touch(at: now)
        }

        energyPreference = .normal
        let ids = planner.recommendations(
            from: pending,
            now: now,
            preference: energyPreference
        ).map(\.task.id)
        let didRollOver = dailyPlan != nil
        savePlan(day: today, taskIDs: ids, preference: energyPreference)
        refreshPlan()

        return DailyPlanUpdate(
            created: !didRollOver,
            rolledOver: didRollOver,
            postponedCount: postponed.count
        )
    }

    func replanDaily(
        from tasks: [LumaTask],
        planner: TaskPlanner,
        preference: EnergyPreference,
        now: Date = .now
    ) {
        energyPreference = preference
        let ids = planner.recommendations(
            from: tasks,
            now: now,
            preference: preference
        ).map(\.task.id)
        savePlan(
            day: calendar.startOfDay(for: now),
            taskIDs: ids,
            preference: preference
        )
        refreshPlan()
    }

    func dailyRecommendations(
        from tasks: [LumaTask],
        planner: TaskPlanner,
        now: Date = .now
    ) -> [PlanRecommendation] {
        guard let dailyPlan, calendar.isDate(dailyPlan.day, inSameDayAs: now) else {
            return planner.recommendations(from: tasks, now: now, preference: energyPreference)
        }

        let ranked = planner.recommendations(
            from: tasks,
            now: now,
            preference: energyPreference,
            limit: tasks.count
        )
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.task.id, $0) })
        let planned = dailyPlan.taskIDs.compactMap { byID[$0] }
        let plannedIDs = Set(planned.map(\.task.id))
        let replacements = ranked.filter { !plannedIDs.contains($0.task.id) }
        return Array((planned + replacements).prefix(3))
    }

    @discardableResult
    func prepareDailyAgenda(
        from tasks: [LumaTask],
        planner: TaskPlanner,
        scheduler: DailyScheduler,
        now: Date = .now,
        force: Bool = false,
        preferredStartMinuteOfDay: Int? = nil,
        busyBlocks: [BusyTimeBlock] = []
    ) -> Bool {
        let today = calendar.startOfDay(for: now)
        let recommendations = dailyRecommendations(from: tasks, planner: planner, now: now)
        let hasCurrentAgenda = dailyAgenda.map { calendar.isDate($0.day, inSameDayAs: today) } ?? false
        let defaultStart = scheduler.defaultStartMinute(now: now)
        let suggestedStart = preferredStartMinuteOfDay.map { max(defaultStart, $0) } ?? defaultStart
        let availabilityWindows = hasCurrentAgenda
            ? (dailyAgenda?.availabilityWindows ?? [])
            : []
        let availabilityConfirmed = hasCurrentAgenda
            ? (dailyAgenda?.availabilityConfirmed ?? false)
            : false
        let availableMinutes = min(480, availabilityWindows.reduce(0) { $0 + $1.durationMinutes })
        let startMinute = availabilityWindows.first?.startMinuteOfDay ?? suggestedStart
        let blocks = availabilityWindows.isEmpty
            ? []
            : scheduler.schedule(
                recommendations: recommendations,
                availabilityWindows: availabilityWindows,
                busyBlocks: busyBlocks
            )

        if hasCurrentAgenda, !force, dailyAgenda?.blocks == blocks {
            return false
        }

        saveAgenda(
            day: today,
            availableMinutes: availableMinutes,
            startMinuteOfDay: startMinute,
            availabilityWindows: availabilityWindows,
            availabilityConfirmed: availabilityConfirmed,
            blocks: blocks
        )
        refreshPlan()
        return true
    }

    func configureDailyAgenda(
        availableMinutes: Int,
        startMinuteOfDay: Int,
        tasks: [LumaTask],
        planner: TaskPlanner,
        scheduler: DailyScheduler,
        now: Date = .now,
        busyBlocks: [BusyTimeBlock] = []
    ) {
        let clampedMinutes = min(480, max(0, availableMinutes))
        let clampedStart = min(23 * 60 + 45, max(0, startMinuteOfDay))
        let windows = clampedMinutes == 0
            ? []
            : [AvailabilityWindow(
                startMinuteOfDay: clampedStart,
                endMinuteOfDay: min(24 * 60, clampedStart + clampedMinutes)
            )]
        configureDailyAgenda(
            availabilityWindows: windows,
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            now: now,
            busyBlocks: busyBlocks
        )
    }

    func configureDailyAgenda(
        availabilityWindows: [AvailabilityWindow],
        tasks: [LumaTask],
        planner: TaskPlanner,
        scheduler: DailyScheduler,
        now: Date = .now,
        busyBlocks: [BusyTimeBlock] = []
    ) {
        let today = calendar.startOfDay(for: now)
        let normalized = scheduler.freeAvailabilityWindows(
            in: availabilityWindows,
            busyBlocks: []
        )
        let availableMinutes = min(480, normalized.reduce(0) { $0 + $1.durationMinutes })
        let startMinute = normalized.first?.startMinuteOfDay ?? scheduler.defaultStartMinute(now: now)
        let recommendations = dailyRecommendations(from: tasks, planner: planner, now: now)
        let blocks = normalized.isEmpty
            ? []
            : scheduler.schedule(
                recommendations: recommendations,
                availabilityWindows: normalized,
                busyBlocks: busyBlocks
            )

        saveAgenda(
            day: today,
            availableMinutes: availableMinutes,
            startMinuteOfDay: startMinute,
            availabilityWindows: normalized,
            availabilityConfirmed: true,
            blocks: blocks
        )
        refreshPlan()
    }

    func applyAgendaRequest(
        _ request: AgendaRequestDraft,
        tasks: [LumaTask],
        planner: TaskPlanner,
        scheduler: DailyScheduler,
        now: Date = .now,
        busyBlocks: [BusyTimeBlock] = []
    ) {
        if let preference = request.energyPreference,
           preference != energyPreference
        {
            replanDaily(
                from: tasks,
                planner: planner,
                preference: preference,
                now: now
            )
        }

        let isCurrentAgenda = dailyAgenda.map { calendar.isDate($0.day, inSameDayAs: now) } ?? false
        if let windows = request.availabilityWindows {
            configureDailyAgenda(
                availabilityWindows: windows,
                tasks: tasks,
                planner: planner,
                scheduler: scheduler,
                now: now,
                busyBlocks: busyBlocks
            )
            return
        }

        let availableMinutes = request.availableMinutes
            ?? (isCurrentAgenda ? dailyAgenda?.availableMinutes : nil)
            ?? 0
        let startMinute = request.startMinuteOfDay
            ?? (isCurrentAgenda ? dailyAgenda?.startMinuteOfDay : nil)
            ?? scheduler.defaultStartMinute(now: now)

        configureDailyAgenda(
            availableMinutes: availableMinutes,
            startMinuteOfDay: startMinute,
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            now: now,
            busyBlocks: busyBlocks
        )
    }

    func availability(for date: Date = .now) -> DayAvailability {
        let weekday = calendar.component(.weekday, from: date)
        return weeklyAvailability.first(where: { $0.weekday == weekday })
            ?? DayAvailability.standardWeek[weekday - 1]
    }

    func updateAvailability(_ availability: DayAvailability) {
        guard let index = weeklyAvailability.firstIndex(where: { $0.weekday == availability.weekday }) else {
            return
        }
        weeklyAvailability[index] = availability
    }

    func completeOnboarding() {
        onboardingCompleted = true
    }

    func restartOnboarding() {
        onboardingCompleted = false
    }

    func startFocus(for taskID: UUID, durationMinutes: Int? = nil) {
        focusTaskID = taskID
        focusDurationMinutes = durationMinutes
        selection = .focus
    }

    func applyReplan(_ proposal: ReplanProposal) {
        energyPreference = proposal.afterEnergy
        savePlan(
            day: proposal.day,
            taskIDs: proposal.afterTaskIDs,
            preference: proposal.afterEnergy
        )
        saveAgenda(
            day: proposal.day,
            availableMinutes: proposal.afterAvailableMinutes,
            startMinuteOfDay: proposal.startMinuteOfDay,
            availabilityWindows: proposal.afterAvailableMinutes > 0
                ? [AvailabilityWindow(
                    startMinuteOfDay: proposal.startMinuteOfDay,
                    endMinuteOfDay: min(24 * 60, proposal.startMinuteOfDay + proposal.afterAvailableMinutes)
                )]
                : [],
            availabilityConfirmed: true,
            blocks: proposal.afterBlocks
        )
        refreshPlan()
    }

    func restoreReplan(_ proposal: ReplanProposal) {
        energyPreference = proposal.beforeEnergy
        savePlan(
            day: proposal.day,
            taskIDs: proposal.beforeTaskIDs,
            preference: proposal.beforeEnergy
        )
        saveAgenda(
            day: proposal.day,
            availableMinutes: proposal.beforeAvailableMinutes,
            startMinuteOfDay: proposal.startMinuteOfDay,
            availabilityWindows: proposal.beforeAvailableMinutes > 0
                ? [AvailabilityWindow(
                    startMinuteOfDay: proposal.startMinuteOfDay,
                    endMinuteOfDay: min(24 * 60, proposal.startMinuteOfDay + proposal.beforeAvailableMinutes)
                )]
                : [],
            availabilityConfirmed: true,
            blocks: proposal.beforeBlocks
        )
        refreshPlan()
    }

    func moveAgendaBlock(
        taskID: UUID,
        to startMinuteOfDay: Int,
        scheduler: DailyScheduler,
        busyBlocks: [BusyTimeBlock]
    ) {
        guard let agenda = dailyAgenda else { return }
        let blocks = scheduler.movedBlocks(
            agenda.blocks,
            taskID: taskID,
            proposedStartMinute: startMinuteOfDay,
            availabilityWindows: agenda.availabilityWindows,
            busyBlocks: busyBlocks
        )
        guard blocks != agenda.blocks else { return }
        saveAgenda(
            day: agenda.day,
            availableMinutes: agenda.availableMinutes,
            startMinuteOfDay: agenda.startMinuteOfDay,
            availabilityWindows: agenda.availabilityWindows,
            availabilityConfirmed: agenda.availabilityConfirmed,
            blocks: blocks
        )
        refreshPlan()
    }

    func restoreAgenda(_ snapshot: DailyAgendaSnapshot) {
        dailyAgenda = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.dailyAgendaKey)
        }
        refreshPlan()
    }

    func registerUndo(message: String, action: @escaping () -> Void) {
        undoDismissTask?.cancel()
        undoMessage = message
        undoHandler = action
        undoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            self?.clearUndo()
        }
    }

    func performUndo() {
        let handler = undoHandler
        clearUndo()
        handler?()
    }

    func clearUndo() {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        undoMessage = nil
        undoHandler = nil
    }

    var preferredBlockOverride: Int? {
        preferredBlockOverrideMinutes > 0 ? preferredBlockOverrideMinutes : nil
    }

    var dailyPlanLabel: String {
        guard let dailyPlan, calendar.isDate(dailyPlan.day, inSameDayAs: .now) else {
            return "Preparando el plan de hoy"
        }
        return dailyPlan.taskIDs.isEmpty
            ? "Plan listo · sin prioridades pendientes"
            : "Plan guardado para hoy · se revisa mañana"
    }

    var dailyAgendaLabel: String {
        guard let dailyAgenda, calendar.isDate(dailyAgenda.day, inSameDayAs: .now) else {
            return "Definí cuánto tiempo tenés hoy"
        }

        if !dailyAgenda.availabilityConfirmed { return "Definí cuánto tiempo tenés hoy" }
        if dailyAgenda.availableMinutes == 0 { return "Día libre · sin bloques" }
        let hours = dailyAgenda.availableMinutes / 60
        let minutes = dailyAgenda.availableMinutes % 60
        let duration: String
        if hours == 0 { duration = "\(minutes) min" }
        else if minutes == 0 { duration = hours == 1 ? "1 hora" : "\(hours) horas" }
        else { duration = "\(hours) h \(minutes) min" }
        let blockCount = dailyAgenda.availabilityWindows.count
        return blockCount > 1 ? "\(duration) en \(blockCount) bloques" : "\(duration) disponibles"
    }

    var isTodayAvailabilityConfirmed: Bool {
        guard let dailyAgenda, calendar.isDate(dailyAgenda.day, inSameDayAs: .now) else { return false }
        return dailyAgenda.availabilityConfirmed
    }

    private func savePlan(day: Date, taskIDs: [UUID], preference: EnergyPreference) {
        let snapshot = DailyPlanSnapshot(
            day: day,
            taskIDs: taskIDs,
            energyPreference: preference
        )
        dailyPlan = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.dailyPlanKey)
        }
    }

    private func saveAgenda(
        day: Date,
        availableMinutes: Int,
        startMinuteOfDay: Int,
        availabilityWindows: [AvailabilityWindow],
        availabilityConfirmed: Bool,
        blocks: [AgendaBlockSnapshot]
    ) {
        let snapshot = DailyAgendaSnapshot(
            day: day,
            availableMinutes: availableMinutes,
            startMinuteOfDay: startMinuteOfDay,
            availabilityWindows: availabilityWindows,
            availabilityConfirmed: availabilityConfirmed,
            blocks: blocks
        )
        dailyAgenda = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.dailyAgendaKey)
        }
    }
}
