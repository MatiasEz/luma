import Foundation

enum WorkBlockStatus: String, Codable {
    case proposed, confirmed, completed
    var title: String {
        switch self {
        case .proposed: "Propuesto"
        case .confirmed: "Confirmado"
        case .completed: "Hecho"
        }
    }
}

struct PlannedWorkBlock: Codable, Equatable, Identifiable {
    var id = UUID()
    var taskID: UUID
    var day: Date
    var minutes: Int
    var startMinute: Int?
    var status: WorkBlockStatus
    var sequence: Int
}

struct PlanCapacityIssue: Codable, Equatable, Identifiable {
    var taskID: UUID
    var dueDate: Date
    var missingMinutes: Int
    var id: UUID { taskID }
}

struct SharedPlanSnapshot: Codable, Equatable {
    var version = 1
    var blocks: [PlannedWorkBlock] = []
    var capacityIssues: [PlanCapacityIssue] = []
    var schedulingWarnings: [String]? = nil
}

/// One pool of capacity per day. Simulated progress is kept on detached copies,
/// never on the user's tasks. Only an explicit action consumes real time.
struct SharedPlanBuilder {
    var calendar: Calendar = .current

    func build(
        tasks: [LumaTask], previous: SharedPlanSnapshot,
        todayPlan: DailyPlanSnapshot?, todayBudget: Int,
        availability: [DayAvailability], preference: EnergyPreference,
        planner: TaskPlanner, now: Date = .now, horizon: Int = 60
    ) -> SharedPlanSnapshot {
        let today = calendar.startOfDay(for: now)
        let originals = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let simulated = tasks.filter { !$0.isCompleted && $0.academicSourceType != .rest && $0.planningDetails.isRetired != true }
            .map { LumaTaskSnapshot(task: $0).makeTask() }
        let simulatedByID = Dictionary(uniqueKeysWithValues: simulated.map { ($0.id, $0) })
        var result = SharedPlanSnapshot()
        result.blocks = previous.blocks.filter {
            $0.status == .completed && originals[$0.taskID] != nil
                && $0.day >= (calendar.date(byAdding: .day, value: -30, to: today) ?? today)
        }
        func consume(_ block: PlannedWorkBlock) {
            guard let task = simulatedByID[block.taskID] else { return }
            task.focusedMinutes += block.minutes
            if task.focusedMinutes >= task.estimatedMinutes { task.status = .completed }
        }
        for offset in 0..<max(1, min(60, horizon)) {
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let weekday = calendar.component(.weekday, from: day)
            let available = availability.first { $0.weekday == weekday }
            let net = offset == 0 ? todayBudget : (available?.isEnabled == false ? 0 : available?.availableMinutes ?? 120)
            let rest = offset == 0 ? todayPlan?.restMinutes ?? 0
                : planner.countsRest ? TaskPlanner.suggestedRestMinutes(availableMinutes: net, preference: .normal) : 0
            var remaining = max(0, net - rest)
            var selected: [UUID] = []
            var sequence = (result.blocks.filter { $0.day == day }.map(\.sequence).max() ?? -1) + 1
            var reusedIDs = Set<UUID>()
            func append(taskID: UUID, minutes: Int, status: WorkBlockStatus) {
                let existing = previous.blocks.sorted { $0.sequence < $1.sequence }.first {
                    $0.taskID == taskID && $0.day == day && !reusedIDs.contains($0.id) && $0.status != .completed
                }
                if let existing { reusedIDs.insert(existing.id) }
                let scheduled = originals[taskID]?.deadline.flatMap { date -> Int? in
                    guard calendar.isDate(date, inSameDayAs: day), !selected.contains(taskID) else { return nil }
                    let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
                    return minute > 0 ? minute : nil
                }
                let block = PlannedWorkBlock(id: existing?.id ?? UUID(), taskID: taskID,
                    day: day, minutes: minutes, startMinute: scheduled,
                    status: status, sequence: sequence)
                result.blocks.append(block)
                if !selected.contains(taskID) { selected.append(taskID) }
                sequence += 1
                remaining -= minutes
                consume(block)
            }
            if offset == 0, let todayPlan, calendar.isDate(todayPlan.day, inSameDayAs: day) {
                let eligible = Set(planner.recommendationsPreservingPlan(from: simulated, taskIDs: todayPlan.taskIDs,
                    now: now, preference: preference, savedMinutes: todayPlan.suggestedMinutesByTaskID,
                    savedRestMinutes: todayPlan.restMinutes, budgetOverride: todayBudget).map(\.id))
                for id in todayPlan.taskIDs where eligible.contains(id) {
                    guard let task = simulatedByID[id], !task.isCompleted, remaining > 0 else { continue }
                    let minutes = min(remaining, min(task.remainingEstimatedMinutes, todayPlan.suggestedMinutesByTaskID?[id] ?? 25))
                    append(taskID: id, minutes: minutes, status: .confirmed)
                }
            }
            while remaining >= 10 {
                // A confirmed day is extended only for its existing priorities.
                let choices = offset == 0
                    ? planner.recommendationsPreservingPlan(from: simulated, taskIDs: selected, now: now, preference: preference, savedRestMinutes: 0, budgetOverride: remaining)
                    : planner.recommendations(from: simulated, now: day, preference: .normal, budgetOverride: remaining)
                let distinctLimit = offset == 0 && preference == .tired ? 2 : 3
                guard let choice = choices.first(where: {
                    (selected.contains($0.id) || selected.count < distinctLimit)
                        && (offset != 0 || todayPlan?.allowExtraSessions == true || planner.isEssentialToday($0.task, in: tasks, now: day))
                }) else { break }
                append(taskID: choice.id, minutes: min(remaining, choice.suggestedMinutes), status: offset == 0 ? .confirmed : .proposed)
            }
        }
        let end = calendar.date(byAdding: .day, value: max(1, min(60, horizon)), to: today) ?? today
        result.capacityIssues = tasks.compactMap { task in
            guard !task.isCompleted, task.academicSourceType != .rest, task.planningDetails.isRetired != true,
                  let due = task.dueDate, due < end, calendar.startOfDay(for: due) >= today else { return nil }
            let target = max(today, calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: due)) ?? today)
            let reserved = result.blocks.filter {
                $0.taskID == task.id && $0.status != .completed && $0.day <= target
            }.reduce(0) { $0 + $1.minutes }
            let missing = max(0, task.remainingEstimatedMinutes - reserved)
            return missing > 0 ? PlanCapacityIssue(taskID: task.id, dueDate: due, missingMinutes: missing) : nil
        }.sorted { $0.dueDate < $1.dueDate }
        return result
    }
}
