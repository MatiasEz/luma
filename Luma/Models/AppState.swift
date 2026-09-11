import Foundation
import Observation

struct DailyPlanSnapshot: Codable, Equatable {
    var day: Date
    var taskIDs: [UUID]
    var energyPreference: EnergyPreference
    var inputFingerprint: String? = nil
    var suggestedMinutesByTaskID: [UUID: Int]? = nil
    var restMinutes: Int? = nil
}

/// Time is spent by a recorded action, never by reserving or reshuffling a block.
struct DailyTimeBudgetSnapshot: Codable, Equatable {
    var day: Date
    var allocatedMinutes: Int
    var consumedMinutesByEventID: [UUID: Int] = [:]

    var consumedMinutes: Int { consumedMinutesByEventID.values.reduce(0, +) }
    var remainingMinutes: Int { min(600, max(0, allocatedMinutes - consumedMinutes)) }
}

struct DailyPlanUpdate: Equatable {
    var created = false
    var rolledOver = false
    var postponedCount = 0
}

enum NavigationItem: String, CaseIterable, Identifiable {
    case today
    case inbox
    case week
    case subjects
    case focus
    case routines
    case exams

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Hoy"
        case .inbox: "Inbox"
        case .week: "Calendario"
        case .subjects: "Materias"
        case .focus: "Focus Room"
        case .routines: "Rutinas"
        case .exams: "Exámenes"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sparkles"
        case .inbox: "tray.full.fill"
        case .week: "calendar"
        case .subjects: "books.vertical.fill"
        case .focus: "moon.zzz.fill"
        case .routines: "arrow.triangle.2.circlepath"
        case .exams: "graduationcap.fill"
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
    private static let dailyTimeBudgetKey = "lumaDailyTimeBudget.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var undoHandler: (() -> Void)?
    @ObservationIgnored private var undoDismissTask: Task<Void, Never>?
    @ObservationIgnored private var dashboardPreparationDay: Date?
    @ObservationIgnored private var dashboardPreparationFingerprint: String?
    @ObservationIgnored private var pendingDailyPlanFingerprintAdoption = false

    var selection: NavigationItem? = .today
    var energyPreference: EnergyPreference = .normal
    var quickCapturePresented = false
    var quickCaptureSeed = ""
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
    private(set) var dailyTimeBudget: DailyTimeBudgetSnapshot?

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: Date = .now
    ) {
        self.defaults = defaults
        self.calendar = calendar
        if let data = defaults.data(forKey: Self.dailyTimeBudgetKey),
           let saved = try? JSONDecoder().decode(DailyTimeBudgetSnapshot.self, from: data),
           saved.allocatedMinutes >= 0,
           saved.consumedMinutesByEventID.values.allSatisfy({ $0 > 0 && $0 <= 1440 })
        {
            dailyTimeBudget = saved
        }
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

    func remainingAvailableMinutes(fallback: Int = 120, now: Date = .now) -> Int {
        guard let dailyTimeBudget, calendar.isDate(dailyTimeBudget.day, inSameDayAs: now) else {
            return min(600, max(0, fallback))
        }
        return dailyTimeBudget.remainingMinutes
    }

    func ensureDailyTimeBudget(availableMinutes: Int, now: Date = .now) {
        guard dailyTimeBudget.map({ calendar.isDate($0.day, inSameDayAs: now) }) != true else { return }
        // Older versions have no reliable daily consumption history. Start with
        // today's declared availability instead of inferring it from lifetime progress.
        saveTimeBudget(DailyTimeBudgetSnapshot(
            day: calendar.startOfDay(for: now),
            allocatedMinutes: min(600, max(0, availableMinutes))
        ))
    }

    /// An explicit "me quedan…" replaces the remaining allowance, not the time spent.
    func setRemainingAvailableMinutes(_ minutes: Int, now: Date = .now) {
        ensureDailyTimeBudget(availableMinutes: minutes, now: now)
        guard var budget = dailyTimeBudget else { return }
        budget.allocatedMinutes = budget.consumedMinutes + min(600, max(0, minutes))
        saveTimeBudget(budget)
    }

    @discardableResult
    func recordTimeSpent(
        eventID: UUID,
        minutes: Int,
        initialAvailableMinutes: Int = 120,
        now: Date = .now
    ) -> Bool {
        guard minutes > 0 else { return false }
        ensureDailyTimeBudget(availableMinutes: initialAvailableMinutes, now: now)
        guard var budget = dailyTimeBudget, budget.consumedMinutesByEventID[eventID] == nil else { return false }
        budget.consumedMinutesByEventID[eventID] = min(1440, minutes)
        saveTimeBudget(budget)
        return true
    }

    @discardableResult
    func undoTimeSpent(eventID: UUID, now: Date = .now) -> Bool {
        guard var budget = dailyTimeBudget,
              calendar.isDate(budget.day, inSameDayAs: now),
              budget.consumedMinutesByEventID.removeValue(forKey: eventID) != nil
        else { return false }
        saveTimeBudget(budget)
        return true
    }

    private func adjustTimeAllowance(by delta: Int, on day: Date) {
        guard delta != 0, var budget = dailyTimeBudget,
              calendar.isDate(budget.day, inSameDayAs: day)
        else { return }
        // Undo only the allowance change. Work recorded since the proposal stays spent.
        budget.allocatedMinutes = max(0, budget.allocatedMinutes + delta)
        saveTimeBudget(budget)
    }

    private func saveTimeBudget(_ budget: DailyTimeBudgetSnapshot) {
        guard let data = try? JSONEncoder().encode(budget) else { return }
        dailyTimeBudget = budget
        defaults.set(data, forKey: Self.dailyTimeBudgetKey)
        refreshPlan()
    }

    func dashboardPreparationIsCurrent(fingerprint: String, now: Date = .now) -> Bool {
        guard let dashboardPreparationDay,
              calendar.isDate(dashboardPreparationDay, inSameDayAs: now)
        else { return false }
        return dashboardPreparationFingerprint == fingerprint
    }

    func markDashboardPrepared(fingerprint: String, now: Date = .now) {
        dashboardPreparationDay = calendar.startOfDay(for: now)
        dashboardPreparationFingerprint = fingerprint
    }

    @discardableResult
    func prepareDailyPlan(
        from tasks: [LumaTask],
        planner: TaskPlanner,
        inputFingerprint: String? = nil,
        now: Date = .now
    ) -> DailyPlanUpdate {
        ensureDailyTimeBudget(availableMinutes: planner.availableTimeBudget, now: now)
        let pending = tasks.filter { !$0.isCompleted }
        let today = calendar.startOfDay(for: now)

        if pendingDailyPlanFingerprintAdoption,
           let inputFingerprint,
           let dailyPlan,
           calendar.isDate(dailyPlan.day, inSameDayAs: today)
        {
            updateDailyPlanInputFingerprint(inputFingerprint)
            return DailyPlanUpdate()
        }

        if let dailyPlan,
           calendar.isDate(dailyPlan.day, inSameDayAs: today),
           inputFingerprint == nil || dailyPlan.inputFingerprint == inputFingerprint
        {
            if dailyPlan.suggestedMinutesByTaskID == nil || dailyPlan.restMinutes == nil {
                _ = dailyRecommendations(from: tasks, planner: planner, now: now)
            }
            return DailyPlanUpdate()
        }

        if let dailyPlan, calendar.isDate(dailyPlan.day, inSameDayAs: today) {
            let recommendations = planner.recommendations(
                from: pending,
                now: now,
                preference: energyPreference,
                budgetOverride: remainingAvailableMinutes(now: now)
            )
            let ids = recommendations.map(\.task.id)
            savePlan(
                day: today,
                taskIDs: ids,
                preference: energyPreference,
                inputFingerprint: inputFingerprint,
                suggestedMinutesByTaskID: Dictionary(uniqueKeysWithValues: recommendations.map {
                    ($0.task.id, $0.suggestedMinutes)
                }),
                restMinutes: planner.restRecommendation(
                    from: tasks, now: now, preference: energyPreference,
                    budgetOverride: remainingAvailableMinutes(now: now)
                )?.suggestedMinutes ?? 0
            )
            refreshPlan()
            return DailyPlanUpdate(created: dailyPlan.taskIDs != ids)
        }

        let previousIDs = Set(dailyPlan?.taskIDs ?? [])
        pendingDailyPlanFingerprintAdoption = false
        let postponed = pending.filter { previousIDs.contains($0.id) }
        postponed.forEach {
            $0.postponementCount += 1
            $0.touch(at: now)
        }

        energyPreference = .normal
        let recommendations = planner.recommendations(
            from: pending,
            now: now,
            preference: energyPreference,
            budgetOverride: remainingAvailableMinutes(now: now)
        )
        let ids = recommendations.map(\.task.id)
        let didRollOver = dailyPlan != nil
        savePlan(
            day: today,
            taskIDs: ids,
            preference: energyPreference,
            inputFingerprint: inputFingerprint,
            suggestedMinutesByTaskID: Dictionary(uniqueKeysWithValues: recommendations.map {
                ($0.task.id, $0.suggestedMinutes)
            }),
            restMinutes: planner.restRecommendation(
                from: tasks, now: now, preference: energyPreference,
                budgetOverride: remainingAvailableMinutes(now: now)
            )?.suggestedMinutes ?? 0
        )
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
        ensureDailyTimeBudget(availableMinutes: planner.availableTimeBudget, now: now)
        pendingDailyPlanFingerprintAdoption = false
        energyPreference = preference
        let recommendations = planner.recommendations(
            from: tasks,
            now: now,
            preference: preference,
            budgetOverride: remainingAvailableMinutes(now: now)
        )
        savePlan(
            day: calendar.startOfDay(for: now),
            taskIDs: recommendations.map(\.task.id),
            preference: preference,
            suggestedMinutesByTaskID: Dictionary(uniqueKeysWithValues: recommendations.map {
                ($0.task.id, $0.suggestedMinutes)
            }),
            restMinutes: planner.restRecommendation(
                from: tasks, now: now, preference: preference,
                budgetOverride: remainingAvailableMinutes(now: now)
            )?.suggestedMinutes ?? 0
        )
        refreshPlan()
    }

    func dailyRecommendations(
        from tasks: [LumaTask],
        planner: TaskPlanner,
        now: Date = .now
    ) -> [PlanRecommendation] {
        ensureDailyTimeBudget(availableMinutes: planner.availableTimeBudget, now: now)
        guard let dailyPlan, calendar.isDate(dailyPlan.day, inSameDayAs: now) else {
            return planner.recommendations(
                from: tasks, now: now, preference: energyPreference,
                budgetOverride: remainingAvailableMinutes(now: now)
            )
        }

        let recommendations = planner.recommendationsPreservingPlan(
            from: tasks,
            taskIDs: dailyPlan.taskIDs,
            now: now,
            preference: energyPreference,
            limit: 3,
            savedMinutes: dailyPlan.suggestedMinutesByTaskID,
            savedRestMinutes: dailyPlan.restMinutes,
            budgetOverride: remainingAvailableMinutes(now: now)
        )
        if dailyPlan.suggestedMinutesByTaskID == nil || dailyPlan.restMinutes == nil {
            savePlan(
                day: dailyPlan.day,
                taskIDs: dailyPlan.taskIDs,
                preference: dailyPlan.energyPreference,
                inputFingerprint: dailyPlan.inputFingerprint,
                suggestedMinutesByTaskID: Dictionary(uniqueKeysWithValues: recommendations.map {
                    ($0.task.id, $0.suggestedMinutes)
                }),
                restMinutes: planner.restRecommendation(
                    from: tasks, now: now, preference: energyPreference,
                    budgetOverride: remainingAvailableMinutes(now: now),
                    savedMinutes: dailyPlan.restMinutes
                )?.suggestedMinutes ?? 0
            )
        }
        return recommendations
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
        let availableMinutes = min(
            remainingAvailableMinutes(fallback: planner.availableTimeBudget, now: now),
            availabilityWindows.reduce(0) { $0 + $1.durationMinutes }
        )
        let startMinute = availabilityWindows.first?.startMinuteOfDay ?? suggestedStart
        let restMinutes = planner.restRecommendation(
            from: tasks,
            now: now,
            preference: energyPreference,
            budgetOverride: availableMinutes,
            savedMinutes: dailyPlan?.restMinutes
        )?.suggestedMinutes ?? 0
        let blocks = availabilityWindows.isEmpty
            ? []
            : scheduler.schedule(
                recommendations: recommendations,
                availabilityWindows: availabilityWindows,
                busyBlocks: busyBlocks,
                reservedRestMinutes: restMinutes
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
        let clampedMinutes = min(600, max(0, availableMinutes))
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
            busyBlocks: [],
            minimumDurationMinutes: 1
        )
        let availableMinutes = min(600, normalized.reduce(0) { $0 + $1.durationMinutes })
        setRemainingAvailableMinutes(availableMinutes, now: now)
        let startMinute = normalized.first?.startMinuteOfDay ?? scheduler.defaultStartMinute(now: now)
        let recommendations = dailyRecommendations(from: tasks, planner: planner, now: now)
        let restMinutes = planner.restRecommendation(
            from: tasks,
            now: now,
            preference: energyPreference,
            budgetOverride: availableMinutes,
            savedMinutes: dailyPlan?.restMinutes
        )?.suggestedMinutes ?? 0
        let blocks = normalized.isEmpty
            ? []
            : scheduler.schedule(
                recommendations: recommendations,
                availabilityWindows: normalized,
                busyBlocks: busyBlocks,
                reservedRestMinutes: restMinutes
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
            ?? remainingAvailableMinutes(fallback: isCurrentAgenda ? (dailyAgenda?.availableMinutes ?? 0) : 0, now: now)
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

    func finishPlannedBlock(for taskID: UUID) {
        guard let dailyPlan else { return }
        savePlan(
            day: dailyPlan.day,
            taskIDs: dailyPlan.taskIDs.filter { $0 != taskID },
            preference: dailyPlan.energyPreference,
            inputFingerprint: dailyPlan.inputFingerprint,
            suggestedMinutesByTaskID: dailyPlan.suggestedMinutesByTaskID?.filter { $0.key != taskID }
        )
        refreshPlan()
    }

    func finishRest(minutes: Int) {
        guard minutes > 0, let dailyPlan, let restMinutes = dailyPlan.restMinutes else { return }
        savePlan(
            day: dailyPlan.day,
            taskIDs: dailyPlan.taskIDs,
            preference: dailyPlan.energyPreference,
            inputFingerprint: dailyPlan.inputFingerprint,
            suggestedMinutesByTaskID: dailyPlan.suggestedMinutesByTaskID,
            restMinutes: max(0, restMinutes - minutes)
        )
        refreshPlan()
    }

    func restoreDailyPlan(_ snapshot: DailyPlanSnapshot?) {
        dailyPlan = snapshot
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.dailyPlanKey)
        } else {
            defaults.removeObject(forKey: Self.dailyPlanKey)
        }
        refreshPlan()
    }

    func applyReplan(_ proposal: ReplanProposal) {
        guard dailyTimeBudget.map({ $0.day <= calendar.startOfDay(for: proposal.day) }) != false else { return }
        ensureDailyTimeBudget(availableMinutes: proposal.beforeAvailableMinutes, now: proposal.day)
        adjustTimeAllowance(
            by: proposal.timeAllowanceAdjustment ?? (proposal.afterAvailableMinutes - proposal.beforeAvailableMinutes),
            on: proposal.day
        )
        pendingDailyPlanFingerprintAdoption = true
        energyPreference = proposal.afterEnergy
        savePlan(
            day: proposal.day,
            taskIDs: proposal.afterTaskIDs,
            preference: proposal.afterEnergy,
            suggestedMinutesByTaskID: proposal.afterSuggestedMinutesByTaskID,
            restMinutes: proposal.afterRestMinutes
        )
        saveAgenda(
            day: proposal.day,
            availableMinutes: remainingAvailableMinutes(fallback: proposal.afterAvailableMinutes, now: proposal.day),
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
        guard dailyTimeBudget.map({ $0.day <= calendar.startOfDay(for: proposal.day) }) != false else { return }
        adjustTimeAllowance(
            by: -(proposal.timeAllowanceAdjustment ?? (proposal.afterAvailableMinutes - proposal.beforeAvailableMinutes)),
            on: proposal.day
        )
        pendingDailyPlanFingerprintAdoption = true
        energyPreference = proposal.beforeEnergy
        savePlan(
            day: proposal.day,
            taskIDs: proposal.beforeTaskIDs,
            preference: proposal.beforeEnergy,
            suggestedMinutesByTaskID: proposal.beforeSuggestedMinutesByTaskID,
            restMinutes: proposal.beforeRestMinutes
        )
        saveAgenda(
            day: proposal.day,
            availableMinutes: remainingAvailableMinutes(fallback: proposal.beforeAvailableMinutes, now: proposal.day),
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

    func updateDailyPlanInputFingerprint(_ fingerprint: String) {
        pendingDailyPlanFingerprintAdoption = false
        guard let dailyPlan else { return }
        savePlan(
            day: dailyPlan.day,
            taskIDs: dailyPlan.taskIDs,
            preference: dailyPlan.energyPreference,
            inputFingerprint: fingerprint,
            suggestedMinutesByTaskID: dailyPlan.suggestedMinutesByTaskID
        )
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
        let remaining = remainingAvailableMinutes(fallback: dailyAgenda.availableMinutes)
        if remaining == 0 { return "Sin tiempo pendiente de usar" }
        let hours = remaining / 60
        let minutes = remaining % 60
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

    private func savePlan(
        day: Date,
        taskIDs: [UUID],
        preference: EnergyPreference,
        inputFingerprint: String? = nil,
        suggestedMinutesByTaskID: [UUID: Int]?,
        restMinutes: Int? = nil
    ) {
        let snapshot = DailyPlanSnapshot(
            day: day,
            taskIDs: taskIDs,
            energyPreference: preference,
            inputFingerprint: inputFingerprint ?? dailyPlan?.inputFingerprint,
            suggestedMinutesByTaskID: suggestedMinutesByTaskID,
            restMinutes: restMinutes ?? dailyPlan.flatMap {
                calendar.isDate($0.day, inSameDayAs: day) ? $0.restMinutes : nil
            }
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
