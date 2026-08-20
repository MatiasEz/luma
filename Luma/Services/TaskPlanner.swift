import Foundation

struct PlanRecommendation: Identifiable {
    let task: LumaTask
    let score: Double
    let reason: String
    let suggestedMinutes: Int

    var id: UUID { task.id }
}

struct TaskPlanner {
    private let calendar: Calendar
    private let rhythmProfile: UserRhythmProfile?
    private let preferredBlockOverride: Int?
    private let preferredAreas: Set<LifeArea>
    private let energyPeak: EnergyPeak?
    private let academicContexts: [UUID: AcademicPriorityContext]

    init(
        calendar: Calendar = .current,
        rhythmProfile: UserRhythmProfile? = nil,
        preferredBlockOverride: Int? = nil,
        preferredAreas: Set<LifeArea> = [],
        energyPeak: EnergyPeak? = nil,
        academicContexts: [UUID: AcademicPriorityContext] = [:]
    ) {
        self.calendar = calendar
        self.rhythmProfile = rhythmProfile
        self.preferredBlockOverride = preferredBlockOverride
        self.preferredAreas = preferredAreas
        self.energyPeak = energyPeak
        self.academicContexts = academicContexts
    }

    func recommendations(
        from tasks: [LumaTask],
        now: Date = .now,
        preference: EnergyPreference = .normal,
        limit: Int = 3
    ) -> [PlanRecommendation] {
        let pending = tasks.filter { !$0.isCompleted }
        let blockedTaskIDs = Set(pending.compactMap(\.unlocksTaskID))
        let actionable = pending.filter { !blockedTaskIDs.contains($0.id) }
        let areaCounts = Dictionary(grouping: pending, by: \.area).mapValues(\.count)

        var selected: [PlanRecommendation] = []
        var remaining = actionable

        while selected.count < min(limit, actionable.count) {
            let ranked = remaining.map { task -> PlanRecommendation in
                var score = baseScore(
                    for: task,
                    now: now,
                    preference: preference,
                    areaCounts: areaCounts
                )

                let repeatedAreaCount = selected.filter { $0.task.area == task.area }.count
                score -= Double(repeatedAreaCount * 10)

                return PlanRecommendation(
                    task: task,
                    score: score,
                    reason: reason(for: task, now: now, preference: preference),
                    suggestedMinutes: suggestedMinutes(for: task, preference: preference)
                )
            }

            guard let next = ranked.max(by: { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.task.createdAt > rhs.task.createdAt
                }
                return lhs.score < rhs.score
            }) else { break }

            selected.append(next)
            remaining.removeAll { $0.id == next.task.id }
        }

        return selected
    }

    func workload(from tasks: [LumaTask], now: Date = .now) -> WorkloadLevel {
        let end = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        let minutes = tasks
            .filter { !$0.isCompleted && ($0.deadline ?? end) <= end }
            .reduce(0) { $0 + $1.remainingEstimatedMinutes }

        return switch minutes {
        case ..<180: .low
        case 180 ..< 480: .medium
        default: .high
        }
    }

    private func baseScore(
        for task: LumaTask,
        now: Date,
        preference: EnergyPreference,
        areaCounts: [LifeArea: Int]
    ) -> Double {
        var score = 0.0

        if let deadline = task.deadline {
            let start = calendar.startOfDay(for: now)
            let due = calendar.startOfDay(for: deadline)
            let days = calendar.dateComponents([.day], from: start, to: due).day ?? 0
            switch days {
            case ...(-1): score += 55
            case 0: score += 48
            case 1: score += 41
            case 2 ... 3: score += 33
            case 4 ... 7: score += 22
            default: score += 10
            }
        } else {
            score += 6
        }

        switch task.impact {
        case .grade, .money: score += 18
        case .urgency: score += 15
        case .wellbeing: score += 13
        case .general: score += 8
        }

        if let weight = task.academicWeight {
            score += min(20, weight * 0.45)
        }

        score += academicContexts[task.id]?.scoreBonus ?? 0

        score += Double(min(15, task.postponementCount * 4))
        if task.unlocksTaskID != nil || task.unlocksAnotherTask { score += 12 }
        if task.remainingEstimatedMinutes <= 45 { score += 4 }

        switch preference {
        case .normal:
            if task.energy == .medium { score += 5 }
        case .tired:
            score += task.energy == .low ? 14 : (task.energy == .medium ? 2 : -16)
        case .energized:
            score += task.energy == .high ? 12 : 4
        }

        let minimumAreaCount = areaCounts.values.min() ?? 0
        if areaCounts[task.area, default: 0] == minimumAreaCount {
            score += 4
        }

        if let rhythmProfile,
           rhythmProfile.isReady,
           let completionRate = rhythmProfile.areaCompletionRates[task.area]
        {
            score += min(4, completionRate * 4)
        }

        if preferredAreas.contains(task.area) {
            score += 3
        }

        if let energyPeak {
            if energyPeak.contains(now, calendar: calendar), task.energy == .high {
                score += 6
            } else if !energyPeak.contains(now, calendar: calendar), task.energy == .low {
                score += 3
            }
        }

        return score
    }

    private func reason(
        for task: LumaTask,
        now: Date,
        preference: EnergyPreference
    ) -> String {
        var fragments: [String] = []

        if let deadline = task.deadline {
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: deadline)
            ).day ?? 0

            switch days {
            case ...(-1): fragments.append("quedó pendiente y conviene destrabarla")
            case 0: fragments.append("vence hoy")
            case 1: fragments.append("vence mañana")
            case 2 ... 7: fragments.append("vence en \(days) días")
            default: break
            }
        }

        if let weight = task.academicWeight {
            fragments.append("vale \(Int(weight))%")
        } else if let academicReason = academicContexts[task.id]?.reason {
            fragments.append(academicReason)
        } else {
            switch task.impact {
            case .money: fragments.append("tiene impacto en dinero")
            case .wellbeing: fragments.append("cuida tu bienestar")
            case .urgency: fragments.append("evita que se acumule")
            case .grade: fragments.append("impacta tu calificación")
            case .general: break
            }
        }

        if task.unlocksTaskID != nil || task.unlocksAnotherTask {
            fragments.append("desbloquea otro pendiente")
        }

        if preference == .tired, task.energy == .low {
            fragments.append("encaja con tu energía de hoy")
        }

        if task.focusedMinutes > 0 {
            fragments.append("ya avanzaste \(task.focusedMinutes) min")
        }

        if let preferredMinutes = adaptiveBlockMinutes,
           task.remainingEstimatedMinutes > preferredMinutes
        {
            fragments.append("encaja mejor en un bloque de \(preferredMinutes) min")
        }

        if fragments.isEmpty {
            fragments.append("es un avance concreto y manejable")
        }

        return fragments.prefix(2).joined(separator: " y ") + "."
    }

    private func suggestedMinutes(for task: LumaTask, preference: EnergyPreference) -> Int {
        if let adaptiveBlockMinutes {
            let learnedMinutes = switch preference {
            case .tired: min(25, adaptiveBlockMinutes)
            case .normal: adaptiveBlockMinutes
            case .energized: min(75, max(45, adaptiveBlockMinutes))
            }
            return min(task.remainingEstimatedMinutes, learnedMinutes)
        }

        return switch preference {
        case .tired: min(task.remainingEstimatedMinutes, 25)
        case .normal: min(task.remainingEstimatedMinutes, 45)
        case .energized: min(task.remainingEstimatedMinutes, 75)
        }
    }

    private var adaptiveBlockMinutes: Int? {
        if let preferredBlockOverride { return preferredBlockOverride }
        guard let rhythmProfile, rhythmProfile.isReady else { return nil }
        return rhythmProfile.preferredBlockMinutes
    }
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
