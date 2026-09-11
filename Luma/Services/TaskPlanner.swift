import Foundation

struct PlanRecommendation: Identifiable {
    let task: LumaTask
    let score: Double
    let reason: String
    let suggestedMinutes: Int

    var id: UUID { task.id }

    var displayTitle: String {
        guard task.remainingEstimatedMinutes > suggestedMinutes else { return task.title }
        return "Avanzar \(suggestedMinutes) min en \(task.title)"
    }
}

struct DailyPlanResult {
    let primary: [PlanRecommendation]
    let optional: PlanRecommendation?
    let rest: PlanRecommendation?
    let scheduledOutsidePlan: [LumaTask]
    let needsCapacityDecision: Bool
}

struct TaskPlanner {
    private static let minimumNewWorkBlockMinutes = 10
    private let calendar: Calendar
    private let rhythmProfile: UserRhythmProfile?
    private let preferredBlockOverride: Int?
    private let preferredAreas: Set<LifeArea>
    private let energyPeak: EnergyPeak?
    private let availableMinutes: Int?
    private let planningMode: PlanningMode
    private let classMeetings: [SubjectClassMeeting]
    private let subjectNames: [UUID: String]
    private let weeklyAvailability: [DayAvailability]
    private let restCounts: Bool
    private var dependencyDates: [UUID: Date] = [:]
    private var contextPrepared = false
    private var contextTasks: [LumaTask] = []

    init(
        calendar: Calendar = .current,
        rhythmProfile: UserRhythmProfile? = nil,
        preferredBlockOverride: Int? = nil,
        preferredAreas: Set<LifeArea> = [],
        energyPeak: EnergyPeak? = nil,
        availableMinutes: Int? = nil,
        planningMode: PlanningMode = .realistic,
        classMeetings: [SubjectClassMeeting] = [],
        subjectNames: [UUID: String] = [:],
        weeklyAvailability: [DayAvailability] = [],
        restCounts: Bool = false
    ) {
        self.calendar = calendar
        self.rhythmProfile = rhythmProfile
        self.preferredBlockOverride = preferredBlockOverride
        self.preferredAreas = preferredAreas
        self.energyPeak = energyPeak
        self.availableMinutes = availableMinutes
        self.planningMode = planningMode
        self.classMeetings = classMeetings
        self.subjectNames = subjectNames
        self.weeklyAvailability = weeklyAvailability
        self.restCounts = restCounts
    }

    func isEssentialToday(_ task: LumaTask, in tasks: [LumaTask], now: Date) -> Bool {
        withContext(tasks).isCriticalToday(task, now: now)
    }

    func busyClassBlocks(on day: Date) -> [BusyTimeBlock] {
        classMeetings.filter { $0.weekday == calendar.component(.weekday, from: day) }.map {
            BusyTimeBlock(title: subjectNames[$0.subjectID] ?? "Clase", startMinuteOfDay: $0.startMinuteOfDay, endMinuteOfDay: $0.endMinuteOfDay)
        }
    }

    var countsRest: Bool { restCounts }
    var availableTimeBudget: Int { planningBudget() }

    func recommendations(
        from tasks: [LumaTask],
        now: Date = .now,
        preference: EnergyPreference = .normal,
        limit: Int = 3,
        budgetOverride: Int? = nil
    ) -> [PlanRecommendation] {
        planningResult(
            from: tasks,
            now: now,
            preference: preference,
            limit: limit,
            budgetOverride: budgetOverride
        ).primary
    }

    func planningResult(
        from tasks: [LumaTask],
        now: Date = .now,
        preference: EnergyPreference = .normal,
        limit: Int = 3,
        budgetOverride: Int? = nil
    ) -> DailyPlanResult {
        if !contextPrepared { return withContext(tasks).planningResult(from: tasks, now: now, preference: preference, limit: limit, budgetOverride: budgetOverride) }
        let pending = tasks.filter { !$0.isCompleted && $0.academicSourceType != .rest }
        let blockedTaskIDs = Set(pending.compactMap(\.unlocksTaskID))
        let actionable = pending.filter {
            !blockedTaskIDs.contains($0.id) && isAvailable($0, now: now) && !requiresOverdueReview($0, now: now)
        }
        let compatible = actionable.filter { isCompatibleWithEnergy($0, now: now, preference: preference) }
        let areaCounts = Dictionary(grouping: pending, by: \.area).mapValues(\.count)
        let subjectCounts = Dictionary(grouping: pending.compactMap { task in
            task.academicSubjectID.map { ($0, task) }
        }, by: { $0.0 }).mapValues(\.count)

        let requestedLimit = min(3, max(0, limit))
        let effectiveLimit = preference == .tired
            ? min(2, requestedLimit)
            : min(requestedLimit, planningMode.taskLimit)
        let rest = restRecommendation(from: tasks, now: now, preference: preference, budgetOverride: budgetOverride)
        let budget = planningBudget(budgetOverride) - (rest?.suggestedMinutes ?? 0)

        var selected: [PlanRecommendation] = []
        var remaining = compatible
        var plannedMinutes = 0

        while selected.count < effectiveLimit,
              !remaining.isEmpty,
              budget - plannedMinutes >= Self.minimumNewWorkBlockMinutes {
            let ranked = remaining.map { task -> PlanRecommendation in
                let base = recommendation(
                    for: task,
                    now: now,
                    preference: preference,
                    areaCounts: areaCounts,
                    subjectCounts: subjectCounts
                )
                let repeatedArea = selected.filter { $0.task.area == task.area }.count
                let repeatedSubject = selected.filter {
                    $0.task.academicSubjectID != nil
                        && $0.task.academicSubjectID == task.academicSubjectID
                }.count
                return PlanRecommendation(
                    task: task,
                    score: base.score - Double(repeatedArea * 7 + repeatedSubject * 6),
                    reason: base.reason,
                    suggestedMinutes: base.suggestedMinutes
                )
            }.sorted { recommendationSort($0, $1, now: now) }

            guard let candidate = ranked.first else { break }
            let fitted = fitting(candidate, to: budget - plannedMinutes, now: now, preference: preference)
            selected.append(fitted)
            plannedMinutes += fitted.suggestedMinutes
            remaining.removeAll { $0.id == candidate.id }
        }

        let selectedIDs = Set(selected.map(\.id))
        let notSelected = actionable.filter { !selectedIDs.contains($0.id) }
        let rankedRemainder = notSelected.filter {
            isCompatibleWithEnergy($0, now: now, preference: preference)
        }.map {
            recommendation(
                for: $0,
                now: now,
                preference: preference,
                areaCounts: areaCounts,
                subjectCounts: subjectCounts
            )
        }.sorted { recommendationSort($0, $1, now: now) }
        let optional = selected.count < 3 && budget - plannedMinutes >= Self.minimumNewWorkBlockMinutes
            ? rankedRemainder.first.map { fitting($0, to: budget - plannedMinutes, now: now, preference: preference) }
            : nil
        let scheduledOutsidePlan = notSelected.filter { isScheduledToday($0, now: now) }
            .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }

        return DailyPlanResult(
            primary: selected,
            optional: optional,
            rest: rest,
            scheduledOutsidePlan: scheduledOutsidePlan,
            needsCapacityDecision: needsCapacityDecision(
                from: tasks,
                recommendations: selected,
                now: now,
                preference: preference
            )
        )
    }

    func needsCapacityDecision(
        from tasks: [LumaTask],
        recommendations: [PlanRecommendation],
        now: Date = .now,
        preference: EnergyPreference = .normal
    ) -> Bool {
        if !contextPrepared { return withContext(tasks).needsCapacityDecision(from: tasks, recommendations: recommendations, now: now, preference: preference) }
        let selectedMinutes = Dictionary(uniqueKeysWithValues: recommendations.map { ($0.id, $0.suggestedMinutes) })
        return tasks.contains { task in
            guard !task.isCompleted,
                  task.academicSourceType != .rest,
                  !requiresOverdueReview(task, now: now),
                  isCriticalToday(task, now: now) || isScheduledToday(task, now: now)
            else { return false }
            let requiredMinutes = isCriticalToday(task, now: now)
                ? task.remainingEstimatedMinutes
                : suggestedMinutes(for: task, preference: preference)
            return selectedMinutes[task.id, default: 0] < requiredMinutes
        }
    }

    /// Keep a useful work block when time is short, reserving at most one third
    /// for rest up to the usual pause. If no useful work block fits, offer a pause.
    static func suggestedRestMinutes(availableMinutes: Int, preference: EnergyPreference) -> Int {
        let budget = max(0, availableMinutes)
        if budget < minimumNewWorkBlockMinutes { return budget }
        guard budget >= minimumNewWorkBlockMinutes + 5 else { return 0 }
        return min(preference == .tired ? 25 : 15, budget / 3)
    }

    /// A confirmed pause keeps its minutes as the day's remaining time decreases.
    /// Rest uses the same time budget, but never takes a work-priority slot.
    func restRecommendation(
        from tasks: [LumaTask],
        now: Date = .now,
        preference: EnergyPreference = .normal,
        budgetOverride: Int? = nil,
        savedMinutes: Int? = nil
    ) -> PlanRecommendation? {
        let budget = planningBudget(budgetOverride)
        let restMinutes = savedMinutes.map { min(budget, max(0, $0)) }
            ?? Self.suggestedRestMinutes(availableMinutes: budget, preference: preference)
        guard restCounts, restMinutes > 0,
              let task = tasks.filter({ task in
                  guard !task.isCompleted, task.academicSourceType == .rest else { return false }
                  return task.sourceOccurrenceDate.map { calendar.isDate($0, inSameDayAs: now) }
                      ?? isScheduledToday(task, now: now)
              }).sorted(by: { $0.createdAt < $1.createdAt }).first
        else { return nil }
        return PlanRecommendation(
            task: task,
            score: 0,
            reason: "La pausa se ajusta al tiempo disponible y está incluida en el total de tu día.",
            suggestedMinutes: restMinutes
        )
    }

    /// A saved plan remains stable. Completing a task removes it, but does not
    /// silently pull another one into the middle of the day.
    func recommendationsPreservingPlan(
        from tasks: [LumaTask],
        taskIDs: [UUID],
        now: Date = .now,
        preference: EnergyPreference = .normal,
        limit: Int = 3,
        savedMinutes: [UUID: Int]? = nil,
        savedRestMinutes: Int? = nil,
        budgetOverride: Int? = nil
    ) -> [PlanRecommendation] {
        if !contextPrepared { return withContext(tasks).recommendationsPreservingPlan(from: tasks, taskIDs: taskIDs, now: now, preference: preference, limit: limit, savedMinutes: savedMinutes, savedRestMinutes: savedRestMinutes, budgetOverride: budgetOverride) }
        let pending = tasks.filter { !$0.isCompleted && $0.academicSourceType != .rest }
        let blockedTaskIDs = Set(pending.compactMap(\.unlocksTaskID))
        let actionable = pending.filter {
            !blockedTaskIDs.contains($0.id) && isAvailable($0, now: now) && !requiresOverdueReview($0, now: now)
        }
        let byID = Dictionary(uniqueKeysWithValues: actionable.map { ($0.id, $0) })
        let areaCounts = Dictionary(grouping: pending, by: \.area).mapValues(\.count)
        let subjectCounts = Dictionary(grouping: pending.compactMap { task in
            task.academicSubjectID.map { ($0, task) }
        }, by: { $0.0 }).mapValues(\.count)

        let rest = restRecommendation(
            from: tasks,
            now: now,
            preference: preference,
            budgetOverride: budgetOverride,
            savedMinutes: savedRestMinutes
        )
        var remainingMinutes = planningBudget(budgetOverride) - (rest?.suggestedMinutes ?? 0)
        var seen = Set<UUID>()
        var result: [PlanRecommendation] = []
        for id in taskIDs.prefix(min(3, max(0, limit))) {
            guard remainingMinutes > 0,
                  seen.insert(id).inserted,
                  let task = byID[id],
                  isCompatibleWithEnergy(task, now: now, preference: preference)
            else { continue }
            let base = recommendation(
                for: task,
                now: now,
                preference: preference,
                areaCounts: areaCounts,
                subjectCounts: subjectCounts
            )
            let minutes = savedDuration(for: base, savedMinutes: savedMinutes, preference: preference)
            guard minutes > 0 else { continue }
            let fitted = withMinutes(base, minutes: min(minutes, remainingMinutes), now: now, preference: preference)
            result.append(fitted)
            remainingMinutes -= fitted.suggestedMinutes
        }
        return result
    }

    func optionalRecommendation(
        from tasks: [LumaTask],
        excluding taskIDs: Set<UUID>,
        now: Date = .now,
        preference: EnergyPreference = .normal,
        savedMinutes: [UUID: Int]? = nil
    ) -> PlanRecommendation? {
        if !contextPrepared { return withContext(tasks).optionalRecommendation(from: tasks, excluding: taskIDs, now: now, preference: preference, savedMinutes: savedMinutes) }
        guard taskIDs.count < 3 else { return nil }
        let allPending = tasks.filter { !$0.isCompleted && $0.academicSourceType != .rest }
        let blocked = Set(allPending.compactMap(\.unlocksTaskID))
        let actionable = allPending.filter {
            !taskIDs.contains($0.id)
                && !blocked.contains($0.id)
                && isAvailable($0, now: now)
                && !requiresOverdueReview($0, now: now)
                && isCompatibleWithEnergy($0, now: now, preference: preference)
        }
        let areaCounts = Dictionary(grouping: allPending, by: \.area).mapValues(\.count)
        let subjectCounts = Dictionary(grouping: allPending.compactMap { task in
            task.academicSubjectID.map { ($0, task) }
        }, by: { $0.0 }).mapValues(\.count)
        let rest = restRecommendation(from: tasks, now: now, preference: preference)
        let planned = recommendationsPreservingPlan(
            from: tasks,
            taskIDs: Array(taskIDs),
            now: now,
            preference: preference,
            savedMinutes: savedMinutes
        )
        let remainingMinutes = planningBudget() - (rest?.suggestedMinutes ?? 0)
            - planned.reduce(0) { $0 + $1.suggestedMinutes }
        guard remainingMinutes >= Self.minimumNewWorkBlockMinutes else { return nil }
        return actionable.map {
            recommendation(
                for: $0,
                now: now,
                preference: preference,
                areaCounts: areaCounts,
                subjectCounts: subjectCounts
            )
        }.sorted { recommendationSort($0, $1, now: now) }.first.map {
            fitting($0, to: remainingMinutes, now: now, preference: preference)
        }
    }

    func scheduledTasksOutsidePlan(
        from tasks: [LumaTask],
        excluding taskIDs: Set<UUID>,
        now: Date = .now
    ) -> [LumaTask] {
        tasks.filter {
            !$0.isCompleted && $0.academicSourceType != .rest
                && !taskIDs.contains($0.id) && isScheduledToday($0, now: now)
        }
            .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
    }

    func overdueTasksNeedingReview(from tasks: [LumaTask], now: Date = .now) -> [LumaTask] {
        let today = calendar.startOfDay(for: now)
        return tasks.filter { task in
            guard !task.isCompleted,
                  task.academicSourceType != .rest,
                  task.dueDate != nil,
                  let target = task.dueDate
            else { return false }
            return calendar.startOfDay(for: target) < today && !isScheduledToday(task, now: now)
        }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    func workload(from tasks: [LumaTask], now: Date = .now) -> WorkloadLevel {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        let minutes = tasks.filter { task in
            !task.isCompleted && task.academicSourceType != .rest && task.planningDetails.isRetired != true
                && (task.dueDate ?? task.deadline).map { $0 < end } == true
        }.reduce(0) { $0 + $1.remainingEstimatedMinutes }
        let capacity = (0..<7).reduce(0) { total, offset in
            total + availableCapacity(on: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }
        guard capacity > 0 else { return minutes > 0 ? .high : .low }
        let ratio = Double(minutes) / Double(capacity)
        return ratio > 1 ? .high : ratio >= 0.6 ? .medium : .low
    }

    private func recommendation(
        for task: LumaTask,
        now: Date,
        preference: EnergyPreference,
        areaCounts: [LifeArea: Int],
        subjectCounts: [UUID: Int]
    ) -> PlanRecommendation {
        let minutes = suggestedMinutes(for: task, preference: preference)
        return PlanRecommendation(
            task: task,
            score: baseScore(
                for: task,
                now: now,
                preference: preference,
                areaCounts: areaCounts,
                subjectCounts: subjectCounts
            ),
            reason: reason(for: task, now: now, preference: preference, suggestedMinutes: minutes),
            suggestedMinutes: minutes
        )
    }

    private func planningBudget(_ override: Int? = nil) -> Int {
        // Availability already means free time after classes and commitments.
        max(0, override ?? availableMinutes ?? 120)
    }

    private func fitting(
        _ recommendation: PlanRecommendation,
        to available: Int,
        now: Date,
        preference: EnergyPreference
    ) -> PlanRecommendation {
        withMinutes(
            recommendation,
            minutes: min(recommendation.suggestedMinutes, max(0, available)),
            now: now,
            preference: preference
        )
    }

    private func withMinutes(
        _ recommendation: PlanRecommendation,
        minutes: Int,
        now: Date,
        preference: EnergyPreference
    ) -> PlanRecommendation {
        PlanRecommendation(
            task: recommendation.task,
            score: recommendation.score,
            reason: reason(for: recommendation.task, now: now, preference: preference, suggestedMinutes: minutes),
            suggestedMinutes: minutes
        )
    }

    private func savedDuration(
        for recommendation: PlanRecommendation,
        savedMinutes: [UUID: Int]?,
        preference: EnergyPreference
    ) -> Int {
        min(
            max(0, savedMinutes?[recommendation.id] ?? recommendation.suggestedMinutes),
            min(recommendation.task.remainingEstimatedMinutes, preference == .tired ? 25 : 45)
        )
    }

    private func isCompatibleWithEnergy(_ task: LumaTask, now: Date, preference: EnergyPreference) -> Bool {
        preference != .tired || task.energy != .high || isCriticalToday(task, now: now)
    }

    private func baseScore(
        for task: LumaTask,
        now: Date,
        preference: EnergyPreference,
        areaCounts: [LifeArea: Int],
        subjectCounts: [UUID: Int]
    ) -> Double {
        var score = 0.0
        let today = calendar.startOfDay(for: now)

        if isScheduledToday(task, now: now) {
            score += 115
        } else if let scheduled = task.deadline {
            let days = daysBetween(today, calendar.startOfDay(for: scheduled))
            if days > 0 { score += max(0, 12 - Double(days * 2)) }
        }

        if let target = targetDate(task) {
            let days = daysBetween(today, calendar.startOfDay(for: target))
            switch days {
            case ...(-1): score += 92
            case 0: score += 78
            case 1: score += 52
            case 2 ... 3: score += 35
            case 4 ... 7: score += 22
            default: score += 7
            }
            score += min(48, progressivePressure(for: task, now: now) * 34)
            if calendar.startOfDay(for: target) > today {
                score += classLoadOpportunityScore(on: now)
            }
        } else {
            score += 5
        }

        switch task.impact {
        case .grade, .money: score += 18
        case .urgency: score += 15
        case .wellbeing: score += 13
        case .general: score += 8
        }

        if task.planningDetails.postponementReason == .lessImportant { score -= 15 }
        if let weight = task.academicWeight { score += min(100, max(0, weight)) * 0.35 }
        // Repeated difficulty calls for a decision, rather than an ever-growing penalty.
        score += Double(min(6, task.postponementCount * 2))
        if task.unlocksTaskID != nil || task.unlocksAnotherTask { score += 12 }

        switch task.academicSourceType {
        case .examStudy: score += 12
        case .routine: score += 8
        case .rest: score += preference == .tired ? 24 : 3
        case nil: break
        }

        switch preference {
        case .normal:
            if task.energy == .medium { score += 5 }
        case .tired:
            score += task.energy == .low ? 18 : (task.energy == .medium ? 2 : -22)
        case .energized:
            score += task.energy == .high ? 12 : 4
        }

        let minimumAreaCount = areaCounts.values.min() ?? 0
        if areaCounts[task.area, default: 0] == minimumAreaCount { score += 4 }
        if let rhythmProfile, rhythmProfile.isReady,
           let completionRate = rhythmProfile.areaCompletionRates[task.area]
        {
            score += min(4, completionRate * 4)
        }
        if preferredAreas.contains(task.area) { score += 3 }

        if let subjectID = task.academicSubjectID {
            let largestLoad = subjectCounts.values.max() ?? 0
            if subjectCounts[subjectID, default: 0] == largestLoad, largestLoad >= 3 { score += 4 }
            if let nextClass = nextClassContext(for: subjectID, now: now),
               mustBeReadyBeforeClass(task, classDate: nextClass.date)
            {
                switch nextClass.daysAway {
                case 0 ... 1: score += 22
                case 2: score += 11
                default: break
                }
            }
        }

        if let energyPeak {
            if energyPeak.contains(now, calendar: calendar), task.energy == .high { score += 6 }
            else if !energyPeak.contains(now, calendar: calendar), task.energy == .low { score += 3 }
        }
        return score
    }

    private func reason(
        for task: LumaTask,
        now: Date,
        preference: EnergyPreference,
        suggestedMinutes: Int
    ) -> String {
        var fragments: [String] = []
        if let step = task.planningDetails.nextStep { fragments.append("podés empezar por: \(step)") }
        let today = calendar.startOfDay(for: now)

        if let scheduled = task.deadline, calendar.isDate(scheduled, inSameDayAs: now) {
            fragments.append("la programaste hoy a las \(scheduled.formatted(.dateTime.hour().minute()))")
        }

        if let dueDate = task.dueDate,
           let target = targetDate(task)
        {
            let targetDays = daysBetween(today, calendar.startOfDay(for: target))
            let dueDays = daysBetween(today, calendar.startOfDay(for: dueDate))
            if dueDays == 0 { fragments.append("se entrega hoy") }
            else if targetDays < 0 { fragments.append("conviene recuperar este avance antes de la entrega") }
            else if targetDays == 0, dueDays == 1 { fragments.append("se entrega mañana y conviene dejarla lista hoy") }
            else if targetDays == 0 { fragments.append("hoy es el último día seguro para avanzar") }
            else if dueDays <= 7 { fragments.append("se entrega en \(dueDays) días") }
        }

        if let inherited = dependencyDates[task.id], inherited < (task.dueDate ?? .distantFuture) {
            fragments.insert("desbloquea una entrega del \(inherited.formatted(.dateTime.day().month(.abbreviated)))", at: 0)
        }
        if let weight = task.academicWeight, weight > 0 { fragments.append("vale \(Int(weight))% de la nota") }

        if task.remainingEstimatedMinutes > suggestedMinutes {
            fragments.append("un bloque de \(suggestedMinutes) min evita dejar todo para el final")
        }

        if let subjectID = task.academicSubjectID,
           let nextClass = nextClassContext(for: subjectID, now: now),
           mustBeReadyBeforeClass(task, classDate: nextClass.date)
        {
            let subject = nextClass.subjectName ?? "esta materia"
            if nextClass.daysAway == 1 { fragments.append("tiene que estar lista antes de \(subject) mañana") }
            else if nextClass.daysAway == 0 { fragments.append("tiene que estar lista antes de \(subject) hoy") }
        }

        if task.unlocksTaskID != nil || task.unlocksAnotherTask { fragments.append("desbloquea otro pendiente") }
        if preference == .tired, task.energy == .low { fragments.append("encaja con tu energía de hoy") }
        if preference == .tired, task.energy == .high, isCriticalToday(task, now: now) {
            fragments.append("necesita atención hoy, con un bloque corto para cuidar tu energía")
        }
        if task.focusedMinutes > 0 { fragments.append("ya avanzaste \(task.focusedMinutes) min") }

        switch task.academicSourceType {
        case .examStudy: fragments.append("adelanta el examen sin concentrar todo al final")
        case .routine: fragments.append("forma parte de tu ritmo semanal")
        case .rest: fragments.append("el descanso también sostiene el plan")
        case nil: break
        }

        if fragments.isEmpty {
            switch task.impact {
            case .grade: fragments.append("es un avance académico concreto")
            case .money: fragments.append("tiene impacto en dinero")
            case .wellbeing: fragments.append("cuida tu bienestar")
            case .urgency: fragments.append("evita que se acumule")
            case .general: fragments.append("es un avance concreto y manejable")
            }
        }
        return fragments.prefix(2).joined(separator: " y ") + "."
    }

    private func isCriticalToday(_ task: LumaTask, now: Date) -> Bool {
        // A calendar choice remains visible, but it does not make demanding
        // work unavoidable on a tired day without a real delivery constraint.
        guard effectiveDueDate(task) != nil,
              let target = targetDate(task)
        else { return false }
        return calendar.startOfDay(for: target) <= calendar.startOfDay(for: now)
    }

    private func requiresOverdueReview(_ task: LumaTask, now: Date) -> Bool {
        guard let due = task.dueDate else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
            && !isScheduledToday(task, now: now)
    }

    private func isScheduledToday(_ task: LumaTask, now: Date) -> Bool {
        task.deadline.map { calendar.isDate($0, inSameDayAs: now) } ?? false
    }

    private func progressivePressure(for task: LumaTask, now: Date) -> Double {
        guard let target = targetDate(task) else { return 0 }
        let today = calendar.startOfDay(for: now)
        let targetDay = calendar.startOfDay(for: target)
        guard targetDay >= today else { return 2 }
        let horizon = min(21, max(0, daysBetween(today, targetDay)))
        let capacity = (0 ... horizon).reduce(0) { total, offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            // A long task normally receives one focused block per day. Using
            // the whole day's capacity here would falsely suggest it can all be
            // postponed and completed in one marathon session.
            return total + min(45, availableCapacity(on: day))
        }
        guard capacity > 0 else { return 2 }
        return Double(task.remainingEstimatedMinutes) / Double(capacity)
    }

    private func availableCapacity(on day: Date) -> Int {
        let weekday = calendar.component(.weekday, from: day)
        let availability = weeklyAvailability.first(where: { $0.weekday == weekday })
        if availability?.isEnabled == false { return 0 }
        let base = availability?.availableMinutes
            ?? availableMinutes
            ?? 120
        return max(0, base - (restCounts ? 15 : 0))
    }

    private func classLoadOpportunityScore(on day: Date) -> Double {
        guard !classMeetings.isEmpty else { return 0 }
        let minutesByWeekday = Dictionary(grouping: classMeetings, by: \.weekday).mapValues {
            $0.reduce(0) { $0 + max(0, $1.endMinuteOfDay - $1.startMinuteOfDay) }
        }
        let average = Double((1 ... 7).reduce(0) { $0 + minutesByWeekday[$1, default: 0] }) / 7.0
        let todayMinutes = Double(minutesByWeekday[calendar.component(.weekday, from: day), default: 0])
        return min(10, max(-10, (average - todayMinutes) / 30.0))
    }

    private func mustBeReadyBeforeClass(_ task: LumaTask, classDate: Date) -> Bool {
        guard task.planningDetails.preparesForClass == true else { return false }
        guard let dueDate = task.dueDate else { return true }
        return calendar.startOfDay(for: dueDate) <= calendar.startOfDay(for: classDate)
    }

    private func nextClassContext(for subjectID: UUID, now: Date) -> NextClassContext? {
        let meetings = classMeetings.filter { $0.subjectID == subjectID }
        guard !meetings.isEmpty else { return nil }
        let startToday = calendar.startOfDay(for: now)
        let todayWeekday = calendar.component(.weekday, from: now)
        let nextDate = meetings.compactMap { meeting -> Date? in
            var offset = (meeting.weekday - todayWeekday + 7) % 7
            var day = calendar.date(byAdding: .day, value: offset, to: startToday) ?? startToday
            var candidate = calendar.date(
                bySettingHour: meeting.startMinuteOfDay / 60,
                minute: meeting.startMinuteOfDay % 60,
                second: 0,
                of: day
            ) ?? day
            if candidate < now {
                offset += 7
                day = calendar.date(byAdding: .day, value: offset, to: startToday) ?? day
                candidate = calendar.date(
                    bySettingHour: meeting.startMinuteOfDay / 60,
                    minute: meeting.startMinuteOfDay % 60,
                    second: 0,
                    of: day
                ) ?? day
            }
            return candidate
        }.min()
        guard let nextDate else { return nil }
        return NextClassContext(
            date: nextDate,
            daysAway: max(0, daysBetween(startToday, calendar.startOfDay(for: nextDate))),
            subjectName: subjectNames[subjectID]
        )
    }

    private func withContext(_ tasks: [LumaTask]) -> TaskPlanner {
        var copy = self
        copy.contextPrepared = true
        copy.contextTasks = tasks
        let pending = Dictionary(uniqueKeysWithValues: tasks.filter { !$0.isCompleted }.map { ($0.id, $0) })
        for task in pending.values {
            var visited: Set<UUID> = [task.id]
            var nextID = task.unlocksTaskID
            var earliest = task.dueDate
            while let id = nextID, visited.insert(id).inserted, let next = pending[id] {
                if let due = next.dueDate { earliest = min(earliest ?? due, due) }
                nextID = next.unlocksTaskID
            }
            copy.dependencyDates[task.id] = earliest
        }
        return copy
    }

    private func effectiveDueDate(_ task: LumaTask) -> Date? {
        dependencyDates[task.id] ?? task.dueDate
    }

    private func targetDate(_ task: LumaTask) -> Date? {
        if let inherited = dependencyDates[task.id], inherited < (task.dueDate ?? .distantFuture) {
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: inherited))
        }
        return task.planningTargetDate(calendar: calendar)
    }

    private func isAvailable(_ task: LumaTask, now: Date) -> Bool {
        let today = calendar.startOfDay(for: now)
        if let scheduled = task.deadline, calendar.startOfDay(for: scheduled) > today { return false }
        let details = task.planningDetails
        if details.isRetired == true { return false }
        if let start = details.startDate, calendar.startOfDay(for: start) > today { return false }
        if let deferred = details.deferredUntil, calendar.startOfDay(for: deferred) > today { return false }
        if details.postponementReason == .waiting { return false }
        if let order = details.studyOrder, let source = task.sourceID {
            return !contextTasks.contains {
                !$0.isCompleted && $0.sourceID == source && $0.id != task.id
                    && ($0.planningDetails.studyOrder ?? Int.max) < order
            }
        }
        return true
    }

    private func suggestedMinutes(for task: LumaTask, preference: EnergyPreference) -> Int {
        if task.planningDetails.postponementReason == .unclear { return min(15, task.remainingEstimatedMinutes) }
        let learned = preferredBlockOverride
            ?? (rhythmProfile?.isReady == true ? rhythmProfile?.preferredBlockMinutes : nil)
            ?? 45
        let block = switch preference {
        case .tired: min(25, learned)
        case .normal: min(45, learned)
        case .energized: 45
        }
        return min(task.remainingEstimatedMinutes, max(10, block))
    }

    private func daysBetween(_ lhs: Date, _ rhs: Date) -> Int {
        calendar.dateComponents([.day], from: lhs, to: rhs).day ?? 0
    }

    private func recommendationSort(_ lhs: PlanRecommendation, _ rhs: PlanRecommendation, now: Date) -> Bool {
        let lhsCritical = isCriticalToday(lhs.task, now: now)
        let rhsCritical = isCriticalToday(rhs.task, now: now)
        if lhsCritical != rhsCritical { return lhsCritical }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let lhsTarget = targetDate(lhs.task) ?? .distantFuture
        let rhsTarget = targetDate(rhs.task) ?? .distantFuture
        if lhsTarget != rhsTarget { return lhsTarget < rhsTarget }
        return lhs.task.createdAt < rhs.task.createdAt
    }
}

private struct NextClassContext {
    let date: Date
    let daysAway: Int
    let subjectName: String?
}

enum WorkloadLevel: String {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: "Baja"
        case .medium: "Media"
        case .high: "Alta"
        }
    }
}
