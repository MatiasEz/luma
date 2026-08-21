import Foundation

enum AcademicInsightLevel: Int, Comparable {
    case calm
    case watch
    case urgent

    static func < (lhs: AcademicInsightLevel, rhs: AcademicInsightLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .calm: "En ritmo"
        case .watch: "Conviene avanzar"
        case .urgent: "Necesita atención"
        }
    }

    var symbol: String {
        switch self {
        case .calm: "checkmark.circle.fill"
        case .watch: "clock.badge.exclamationmark"
        case .urgent: "exclamationmark.triangle.fill"
        }
    }
}

struct AcademicSubjectInsight: Identifiable {
    let subjectID: UUID
    let subjectName: String
    let taskID: UUID
    let taskTitle: String
    let deadline: Date?
    let categoryWeight: Double?
    let recommendedMinutes: Int
    let level: AcademicInsightLevel
    let reason: String
    let score: Double

    var id: UUID { subjectID }
}

enum AcademicInsightEngine {
    static func insights(
        subjects: [AcademicSubject],
        items: [SubjectGradeItem],
        tasks: [LumaTask],
        now: Date = .now
    ) -> [AcademicSubjectInsight] {
        let activeItems = items.filter { !$0.isArchived }
        let itemByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        return subjects.compactMap { subject -> AcademicSubjectInsight? in
            guard !subject.isArchived else { return nil }
            let subjectTasks = tasks.filter { $0.academicSubjectID == subject.id }
            let pending = subjectTasks
                .filter { !$0.isCompleted }
                .sorted { left, right in
                    switch (left.deadline, right.deadline) {
                    case let (leftDate?, rightDate?): leftDate < rightDate
                    case (.some, .none): true
                    case (.none, .some): false
                    case (.none, .none): left.createdAt < right.createdAt
                    }
                }
            guard let task = pending.first else { return nil }

            let summary = SubjectGradeCalculator.makeSummary(
                items: activeItems.filter { $0.subjectID == subject.id },
                tasks: subjectTasks
            )
            let required = subject.targetGrade.flatMap { summary.requiredAverage(for: $0) }
            let weight = task.subjectGradeItemID.flatMap { itemByID[$0]?.weightPercent }
            let days = task.deadline.map {
                calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0)).day ?? 0
            }

            var score = Double(task.postponementCount * 8)
            if let days {
                switch days {
                case ...0: score += 55
                case 1: score += 42
                case 2 ... 3: score += 30
                case 4 ... 7: score += 18
                default: score += 4
                }
            }
            if let weight { score += min(24, weight * 0.55) }
            if let required {
                if required > 10 { score += 35 }
                else if let target = subject.targetGrade, required > target { score += 14 }
            }

            let level: AcademicInsightLevel = score >= 58 ? .urgent : (score >= 28 ? .watch : .calm)
            let suggested = min(
                120,
                max(25, min(task.remainingEstimatedMinutes, 35 + Int((weight ?? 15) * 0.8)))
            )
            let reason = reason(
                task: task,
                subject: subject,
                days: days,
                weight: weight,
                requiredAverage: required
            )

            return AcademicSubjectInsight(
                subjectID: subject.id,
                subjectName: subject.name,
                taskID: task.id,
                taskTitle: task.title,
                deadline: task.deadline,
                categoryWeight: weight,
                recommendedMinutes: suggested,
                level: level,
                reason: reason,
                score: score
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
    }

    private static func reason(
        task: LumaTask,
        subject: AcademicSubject,
        days: Int?,
        weight: Double?,
        requiredAverage: Double?
    ) -> String {
        var parts: [String] = []
        if let days {
            if days < 0 { parts.append("está vencida") }
            else if days == 0 { parts.append("vence hoy") }
            else if days == 1 { parts.append("vence mañana") }
            else if days <= 7 { parts.append("vence en \(days) días") }
        }
        if let weight { parts.append("su categoría pesa \(weight.formatted(.number.precision(.fractionLength(0 ... 1))))%") }
        if let requiredAverage {
            if requiredAverage > 10 { parts.append("el objetivo necesita una revisión") }
            else if let target = subject.targetGrade, requiredAverage > target {
                parts.append("necesitás aproximadamente \(requiredAverage.formatted(.number.precision(.fractionLength(0 ... 2)))) en lo pendiente")
            }
        }
        if task.postponementCount > 0 { parts.append("ya fue postergada") }
        return parts.isEmpty ? "Es el próximo avance académico disponible." : parts.joined(separator: " · ") + "."
    }
}
