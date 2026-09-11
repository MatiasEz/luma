import Foundation
import SwiftData

@Model
final class AcademicSubject {
    @Attribute(.unique) var id: UUID
    var name: String
    var targetGrade: Double?
    var colorHex: String = "#59639A"
    var syllabusRaw: String = ""
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        targetGrade: Double? = nil,
        colorHex: String = "#59639A",
        syllabusRaw: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.targetGrade = targetGrade
        self.colorHex = colorHex
        self.syllabusRaw = syllabusRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }

    var syllabusTopics: [String] {
        get {
            syllabusStudyTopics.map(\.title)
        }
        set {
            var currentTopics: [String: StudyTopic] = [:]
            for topic in syllabusStudyTopics {
                currentTopics[Self.normalized(topic.title)] = topic
            }
            let updatedTopics = newValue.compactMap { rawTitle -> StudyTopic? in
                let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                if var existing = currentTopics[Self.normalized(title)] {
                    existing.title = title
                    return existing
                }
                return Self.placeholderTopic(title: title, subjectName: name)
            }
            updateSyllabus(
                topics: updatedTopics,
                sourceFileName: syllabusSourceFileName,
                pageCount: syllabusPageCount
            )
        }
    }

    var syllabusStudyTopics: [StudyTopic] {
        if let storedSyllabus { return storedSyllabus.topics }
        return syllabusRaw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Self.placeholderTopic(title: $0, subjectName: name) }
    }

    var syllabusSourceFileName: String {
        storedSyllabus?.sourceFileName ?? ""
    }

    var syllabusPageCount: Int {
        storedSyllabus?.pageCount ?? 0
    }

    var hasSyllabusPDF: Bool {
        !syllabusSourceFileName.isEmpty
    }

    func updateSyllabus(
        topics: [StudyTopic],
        sourceFileName: String,
        pageCount: Int
    ) {
        let structuredTopics = topics.map { original in
            var topic = original
            if topic.subtopics?.isEmpty != false {
                let recoveredSubtopics = topic.syllabusSubtopics
                topic.subtopics = recoveredSubtopics.isEmpty ? nil : recoveredSubtopics
            }
            return topic
        }
        let payload = StoredSubjectSyllabus(
            version: 2,
            sourceFileName: sourceFileName,
            pageCount: max(0, pageCount),
            topics: structuredTopics
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            syllabusRaw = structuredTopics.map(\.title).joined(separator: "\n")
            return
        }
        syllabusRaw = Self.syllabusStoragePrefix + data.base64EncodedString()
    }

    private var storedSyllabus: StoredSubjectSyllabus? {
        guard syllabusRaw.hasPrefix(Self.syllabusStoragePrefix) else { return nil }
        let encoded = String(syllabusRaw.dropFirst(Self.syllabusStoragePrefix.count))
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(StoredSubjectSyllabus.self, from: data)
    }

    private static let syllabusStoragePrefix = "LUMA-SYLLABUS-V1:"

    private static func placeholderTopic(title: String, subjectName: String) -> StudyTopic {
        StudyTopic(
            title: title,
            summary: "Tema incluido en el temario de \(subjectName).",
            keyPoints: [],
            sourcePages: [],
            importance: 2,
            suggestedMinutes: 35,
            taskID: nil
        )
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct StoredSubjectSyllabus: Codable {
    var version: Int
    var sourceFileName: String
    var pageCount: Int
    var topics: [StudyTopic]
}

@Model
final class SubjectGradeItem {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var title: String
    var weightPercent: Double
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        subjectID: UUID,
        title: String,
        weightPercent: Double,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false
    ) {
        self.id = id
        self.subjectID = subjectID
        self.title = title
        self.weightPercent = weightPercent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}
