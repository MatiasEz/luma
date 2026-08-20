import Foundation

struct StudyTaskDraft: Equatable, Sendable {
    var topicID: UUID?
    var title: String
    var deadline: Date
    var estimatedMinutes: Int
    var energy: EnergyLevel
    var notes: String
}

enum StudyScheduleBuilder {
    static func drafts(
        guideID: UUID,
        guideTitle: String,
        topics: [StudyTopic],
        examDate: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [StudyTaskDraft] {
        let today = calendar.startOfDay(for: now)
        let examDay = max(calendar.startOfDay(for: examDate), calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        let lastStudyDay = calendar.date(byAdding: .day, value: -1, to: examDay) ?? examDay
        let availableDays = max(1, calendar.dateComponents([.day], from: today, to: lastStudyDay).day ?? 1)
        let orderedTopics = topics.sorted { lhs, rhs in
            let leftPage = lhs.sourcePages.min() ?? Int.max
            let rightPage = rhs.sourcePages.min() ?? Int.max
            if leftPage == rightPage { return lhs.importance > rhs.importance }
            return leftPage < rightPage
        }

        var result = orderedTopics.enumerated().map { index, topic in
            let dayOffset = min(
                availableDays,
                max(0, Int(floor(Double(index + 1) * Double(availableDays) / Double(orderedTopics.count + 1))))
            )
            let deadline = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            let marker = "LUMA-STUDY-GUIDE:\(guideID.uuidString)\nLUMA-STUDY-TOPIC:\(topic.id.uuidString)"
            return StudyTaskDraft(
                topicID: topic.id,
                title: "Estudiar: \(topic.title)",
                deadline: deadline,
                estimatedMinutes: min(90, max(20, topic.suggestedMinutes)),
                energy: topic.importance >= 3 ? .high : .medium,
                notes: "\(guideTitle) · \(topic.pageLabel)\n\(marker)"
            )
        }

        result.append(StudyTaskDraft(
            topicID: nil,
            title: "Repaso general: \(guideTitle)",
            deadline: lastStudyDay,
            estimatedMinutes: min(75, max(30, topics.reduce(0) { $0 + $1.suggestedMinutes } / max(1, topics.count))),
            energy: .medium,
            notes: "Repaso final antes del examen.\nLUMA-STUDY-GUIDE:\(guideID.uuidString)\nLUMA-STUDY-REVIEW"
        ))

        return result
    }
}
