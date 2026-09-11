import Foundation
import CryptoKit

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
        let orderedTopics = topics

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

        if orderedTopics.count > 2 {
            var interleaved: [StudyTaskDraft] = []
            for (index, draft) in result.enumerated() {
                interleaved.append(draft)
                if (index + 1).isMultiple(of: 2), index + 1 < result.count {
                    let digest = Array(SHA256.hash(data: Data("review-\(guideID)-\(draft.topicID!)".utf8)))
                    let reviewID = UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
                    interleaved.append(StudyTaskDraft(topicID: reviewID, title: "Repasar lo estudiado: \(orderedTopics[index].title)",
                        deadline: draft.deadline, estimatedMinutes: 15, energy: .low,
                        notes: "Repasar únicamente los temas anteriores, antes de seguir."))
                }
            }
            result = interleaved
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
