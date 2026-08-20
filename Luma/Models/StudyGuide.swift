import Foundation
import SwiftData

struct StudySourcePage: Codable, Hashable, Sendable {
    var pageNumber: Int
    var text: String
}

struct ExtractedStudyDocument: Sendable {
    var title: String
    var fileName: String
    var pageCount: Int
    var pages: [StudySourcePage]
}

struct StudyTopic: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var summary: String
    var keyPoints: [String]
    var sourcePages: [Int]
    var importance: Int
    var suggestedMinutes: Int
    var taskID: UUID?

    var pageLabel: String {
        let pages = Array(Set(sourcePages)).sorted()
        guard let first = pages.first else { return "Sin página" }
        guard let last = pages.last, last != first else { return "Pág. \(first)" }
        return "Págs. \(first)–\(last)"
    }
}

struct StudyFlashcard: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var front: String
    var back: String
    var sourcePage: Int?
    var isMastered = false
}

struct StudyQuizQuestion: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var prompt: String
    var options: [String]
    var correctIndex: Int
    var explanation: String
    var sourcePage: Int?

    var safeCorrectIndex: Int {
        options.indices.contains(correctIndex) ? correctIndex : 0
    }
}

struct GeneratedStudySystem: Sendable {
    var overview: String
    var topics: [StudyTopic]
    var flashcards: [StudyFlashcard]
    var questions: [StudyQuizQuestion]
}

struct StudyTextChunk: Hashable, Sendable {
    var pageNumbers: [Int]
    var text: String
}

enum StudyTextChunker {
    static func chunks(
        from pages: [StudySourcePage],
        maximumChunks: Int = 8,
        maximumCharacters: Int = 9_000
    ) -> [StudyTextChunk] {
        let usefulPages = pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usefulPages.isEmpty else { return [] }

        let chunkCount = min(max(1, maximumChunks), usefulPages.count)
        let pagesPerChunk = Int(ceil(Double(usefulPages.count) / Double(chunkCount)))
        var result: [StudyTextChunk] = []

        for start in stride(from: 0, to: usefulPages.count, by: pagesPerChunk) {
            let group = Array(usefulPages[start ..< min(start + pagesPerChunk, usefulPages.count)])
            let headerBudget = group.count * 18
            let perPageBudget = max(500, (maximumCharacters - headerBudget) / max(1, group.count))
            let text = group.map { page in
                "[PÁGINA \(page.pageNumber)]\n\(excerpt(page.text, limit: perPageBudget))"
            }.joined(separator: "\n\n")

            result.append(StudyTextChunk(
                pageNumbers: group.map(\.pageNumber),
                text: String(text.prefix(maximumCharacters))
            ))
        }

        return Array(result.prefix(maximumChunks))
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"(\p{L})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }

        let firstCount = Int(Double(limit) * 0.68)
        let lastCount = max(0, limit - firstCount - 36)
        return "\(cleaned.prefix(firstCount))\n[…contenido intermedio abreviado…]\n\(cleaned.suffix(lastCount))"
    }
}

@Model
final class StudyGuide {
    @Attribute(.unique) var id: UUID
    var title: String
    var sourceFileName: String
    var importedAt: Date
    var examDate: Date
    var pageCount: Int
    var overview: String
    var generatedAt: Date
    var generationVersion: Int = 1
    var sourcePagesData: Data
    var topicsData: Data
    var flashcardsData: Data
    var questionsData: Data
    var reviewTaskID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        sourceFileName: String,
        importedAt: Date = .now,
        examDate: Date,
        pageCount: Int,
        overview: String,
        generatedAt: Date = .now,
        generationVersion: Int = 2,
        sourcePages: [StudySourcePage] = [],
        topics: [StudyTopic] = [],
        flashcards: [StudyFlashcard] = [],
        questions: [StudyQuizQuestion] = [],
        reviewTaskID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
        self.examDate = examDate
        self.pageCount = pageCount
        self.overview = overview
        self.generatedAt = generatedAt
        self.generationVersion = generationVersion
        sourcePagesData = Self.encode(sourcePages)
        topicsData = Self.encode(topics)
        flashcardsData = Self.encode(flashcards)
        questionsData = Self.encode(questions)
        self.reviewTaskID = reviewTaskID
    }

    var sourcePages: [StudySourcePage] {
        get { Self.decode([StudySourcePage].self, from: sourcePagesData) }
        set { sourcePagesData = Self.encode(newValue) }
    }

    var topics: [StudyTopic] {
        get { Self.decode([StudyTopic].self, from: topicsData) }
        set { topicsData = Self.encode(newValue) }
    }

    var flashcards: [StudyFlashcard] {
        get { Self.decode([StudyFlashcard].self, from: flashcardsData) }
        set { flashcardsData = Self.encode(newValue) }
    }

    var questions: [StudyQuizQuestion] {
        get { Self.decode([StudyQuizQuestion].self, from: questionsData) }
        set { questionsData = Self.encode(newValue) }
    }

    var plannedTopicCount: Int {
        topics.filter { $0.taskID != nil }.count
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T where T: RangeReplaceableCollection {
        (try? JSONDecoder().decode(type, from: data)) ?? T()
    }
}
