import Foundation

struct UserRhythmProfile: Equatable {
    static let minimumSessionCount = 5

    var sessionCount: Int
    var totalMinutes: Int
    var weeklySessionCount: Int
    var weeklyMinutes: Int
    var preferredBlockMinutes: Int
    var bestStartHour: Int?
    var taskCompletionRate: Double
    var estimationRatio: Double
    var topArea: LifeArea?
    var areaCompletionRates: [LifeArea: Double]

    var isReady: Bool { sessionCount >= Self.minimumSessionCount }
    var sessionsUntilReady: Int { max(0, Self.minimumSessionCount - sessionCount) }
    var learningProgress: Double {
        min(1, Double(sessionCount) / Double(Self.minimumSessionCount))
    }

    var bestWindowTitle: String {
        guard let bestStartHour else { return "Todavía aprendiendo" }
        let endHour = min(24, bestStartHour + 2)
        return String(format: "%02d:00–%02d:00", bestStartHour, endHour)
    }

    var estimationTitle: String {
        if estimationRatio > 1.15 { return "Suele necesitar un poco más de tiempo" }
        if estimationRatio < 0.75 { return "Los bloques cortos te funcionan bien" }
        return "Tus estimaciones vienen bastante parejas"
    }
}

struct BehaviorLearningEngine {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func profile(from sessions: [FocusSession], now: Date = .now) -> UserRhythmProfile {
        let monthStart = calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let weekStart = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        let usable = sessions.filter {
            !$0.ignoredFromLearning && $0.endedAt >= monthStart && $0.endedAt <= now
        }
        let weekly = usable.filter { $0.endedAt >= weekStart }

        let preferredBlock = preferredBlockMinutes(from: usable)
        let bestHour = mostFrequentHour(from: usable)
        let completedCount = usable.filter(\.completedTask).count
        let completionRate = usable.isEmpty ? 0 : Double(completedCount) / Double(usable.count)
        let measurable = usable.filter { $0.actualMinutes >= 5 && $0.plannedMinutes > 0 }
        let ratio = measurable.isEmpty
            ? 1
            : measurable.map { Double($0.actualMinutes) / Double($0.plannedMinutes) }.reduce(0, +)
            / Double(measurable.count)
        let minutesByArea = Dictionary(grouping: usable, by: \.area)
            .mapValues { $0.reduce(0) { $0 + $1.actualMinutes } }
        let topArea = minutesByArea.max(by: { $0.value < $1.value })?.key

        return UserRhythmProfile(
            sessionCount: usable.count,
            totalMinutes: usable.reduce(0) { $0 + $1.actualMinutes },
            weeklySessionCount: weekly.count,
            weeklyMinutes: weekly.reduce(0) { $0 + $1.actualMinutes },
            preferredBlockMinutes: preferredBlock,
            bestStartHour: bestHour,
            taskCompletionRate: completionRate,
            estimationRatio: ratio,
            topArea: topArea,
            areaCompletionRates: areaCompletionRates(from: usable)
        )
    }

    func weeklySummary(for profile: UserRhythmProfile) -> String {
        guard profile.weeklySessionCount > 0 else {
            return "Todavía no hay sesiones esta semana. Con cada Focus Room, Luma aprende un poco más de tu ritmo."
        }

        if !profile.isReady {
            let noun = profile.sessionsUntilReady == 1 ? "sesión" : "sesiones"
            return "Registraste \(profile.weeklyMinutes) minutos esta semana. Faltan \(profile.sessionsUntilReady) \(noun) para empezar a adaptar el plan con confianza."
        }

        let areaText = profile.topArea.map { " Tu área más trabajada fue \($0.title)." } ?? ""
        return "Esta semana hiciste \(profile.weeklySessionCount) sesiones y sumaste \(profile.weeklyMinutes) minutos. Tu bloque más natural ronda los \(profile.preferredBlockMinutes) minutos.\(areaText)"
    }

    private func preferredBlockMinutes(from sessions: [FocusSession]) -> Int {
        guard !sessions.isEmpty else { return 25 }
        let options = [15, 25, 45, 60]
        let grouped = Dictionary(grouping: sessions) { session in
            options.min(by: { abs($0 - session.actualMinutes) < abs($1 - session.actualMinutes) }) ?? 25
        }
        return grouped.max(by: { lhs, rhs in
            if lhs.value.count == rhs.value.count { return lhs.key > rhs.key }
            return lhs.value.count < rhs.value.count
        })?.key ?? 25
    }

    private func mostFrequentHour(from sessions: [FocusSession]) -> Int? {
        guard !sessions.isEmpty else { return nil }
        let grouped = Dictionary(grouping: sessions) { calendar.component(.hour, from: $0.startedAt) }
        return grouped.max(by: { lhs, rhs in
            let lhsMinutes = lhs.value.reduce(0) { $0 + $1.actualMinutes }
            let rhsMinutes = rhs.value.reduce(0) { $0 + $1.actualMinutes }
            if lhsMinutes == rhsMinutes { return lhs.key > rhs.key }
            return lhsMinutes < rhsMinutes
        })?.key
    }

    private func areaCompletionRates(from sessions: [FocusSession]) -> [LifeArea: Double] {
        Dictionary(grouping: sessions, by: \.area).reduce(into: [:]) { result, item in
            guard item.value.count >= 2 else { return }
            let completed = item.value.filter(\.completedTask).count
            result[item.key] = Double(completed) / Double(item.value.count)
        }
    }
}
