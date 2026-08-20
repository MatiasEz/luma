import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LumaBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LumaBackupPayload: Codable {
    var version = 1
    var exportedAt = Date.now
    var tasks: [TaskRecord]
    var sessions: [SessionRecord]
    var studyGuides: [StudyGuideRecord]? = nil
    var subjects: [SubjectRecord]? = nil
    var subjectGradeItems: [SubjectGradeItemRecord]? = nil

    struct TaskRecord: Codable {
        var id: UUID
        var title: String
        var areaRaw: String
        var deadline: Date?
        var estimatedMinutes: Int
        var energyRaw: String
        var impactRaw: String
        var academicWeight: Double?
        var academicSubjectID: UUID?
        var subjectGradeItemID: UUID?
        var grade: Double?
        var statusRaw: String
        var createdAt: Date
        var completedAt: Date?
        var postponementCount: Int
        var unlocksAnotherTask: Bool
        var unlocksTaskID: UUID?
        var notes: String
        var focusedMinutes: Int
        var focusSessionCount: Int
        var lastFocusedAt: Date?
    }

    struct SessionRecord: Codable {
        var id: UUID
        var taskID: UUID
        var taskTitle: String
        var areaRaw: String
        var plannedMinutes: Int
        var actualMinutes: Int
        var startedAt: Date
        var endedAt: Date
        var energyPreferenceRaw: String
        var completedTask: Bool
        var ignoredFromLearning: Bool
    }

    struct StudyGuideRecord: Codable {
        var id: UUID
        var title: String
        var sourceFileName: String
        var importedAt: Date
        var examDate: Date
        var pageCount: Int
        var overview: String
        var generatedAt: Date
        var generationVersion: Int?
        var sourcePages: [StudySourcePage]
        var topics: [StudyTopic]
        var flashcards: [StudyFlashcard]
        var questions: [StudyQuizQuestion]
        var reviewTaskID: UUID?
    }

    struct SubjectRecord: Codable {
        var id: UUID
        var name: String
        var targetGrade: Double?
        var createdAt: Date
        var updatedAt: Date
        var isArchived: Bool
    }

    struct SubjectGradeItemRecord: Codable {
        var id: UUID
        var subjectID: UUID
        var title: String
        var weightPercent: Double
        var createdAt: Date
        var updatedAt: Date
        var isArchived: Bool
    }
}

@MainActor
enum BackupService {
    static func document(
        tasks: [LumaTask],
        sessions: [FocusSession],
        studyGuides: [StudyGuide] = [],
        subjects: [AcademicSubject] = [],
        subjectGradeItems: [SubjectGradeItem] = []
    ) throws -> LumaBackupDocument {
        let payload = LumaBackupPayload(
            tasks: tasks.map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    areaRaw: $0.areaRaw,
                    deadline: $0.deadline,
                    estimatedMinutes: $0.estimatedMinutes,
                    energyRaw: $0.energyRaw,
                    impactRaw: $0.impactRaw,
                    academicWeight: $0.academicWeight,
                    academicSubjectID: $0.academicSubjectID,
                    subjectGradeItemID: $0.subjectGradeItemID,
                    grade: $0.grade,
                    statusRaw: $0.statusRaw,
                    createdAt: $0.createdAt,
                    completedAt: $0.completedAt,
                    postponementCount: $0.postponementCount,
                    unlocksAnotherTask: $0.unlocksAnotherTask,
                    unlocksTaskID: $0.unlocksTaskID,
                    notes: $0.notes,
                    focusedMinutes: $0.focusedMinutes,
                    focusSessionCount: $0.focusSessionCount,
                    lastFocusedAt: $0.lastFocusedAt
                )
            },
            sessions: sessions.map {
                .init(
                    id: $0.id,
                    taskID: $0.taskID,
                    taskTitle: $0.taskTitle,
                    areaRaw: $0.areaRaw,
                    plannedMinutes: $0.plannedMinutes,
                    actualMinutes: $0.actualMinutes,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt,
                    energyPreferenceRaw: $0.energyPreferenceRaw,
                    completedTask: $0.completedTask,
                    ignoredFromLearning: $0.ignoredFromLearning
                )
            },
            studyGuides: studyGuides.map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    sourceFileName: $0.sourceFileName,
                    importedAt: $0.importedAt,
                    examDate: $0.examDate,
                    pageCount: $0.pageCount,
                    overview: $0.overview,
                    generatedAt: $0.generatedAt,
                    generationVersion: $0.generationVersion,
                    sourcePages: $0.sourcePages,
                    topics: $0.topics,
                    flashcards: $0.flashcards,
                    questions: $0.questions,
                    reviewTaskID: $0.reviewTaskID
                )
            },
            subjects: subjects.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    targetGrade: $0.targetGrade,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    isArchived: $0.isArchived
                )
            },
            subjectGradeItems: subjectGradeItems.map {
                .init(
                    id: $0.id,
                    subjectID: $0.subjectID,
                    title: $0.title,
                    weightPercent: $0.weightPercent,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    isArchived: $0.isArchived
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try LumaBackupDocument(data: encoder.encode(payload))
    }

    @discardableResult
    static func restore(
        data: Data,
        existingTasks: [LumaTask],
        existingSessions: [FocusSession],
        existingStudyGuides: [StudyGuide] = [],
        existingSubjects: [AcademicSubject] = [],
        existingSubjectGradeItems: [SubjectGradeItem] = [],
        context: ModelContext
    ) throws -> (tasks: Int, sessions: Int, studyGuides: Int, subjects: Int, subjectGradeItems: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LumaBackupPayload.self, from: data)
        guard payload.version == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }

        let taskIDs = Set(existingTasks.map(\.id))
        let sessionIDs = Set(existingSessions.map(\.id))
        let studyGuideIDs = Set(existingStudyGuides.map(\.id))
        let subjectIDs = Set(existingSubjects.map(\.id))
        let subjectGradeItemIDs = Set(existingSubjectGradeItems.map(\.id))
        var restoredTasks = 0
        var restoredSessions = 0
        var restoredStudyGuides = 0
        var restoredSubjects = 0
        var restoredSubjectGradeItems = 0

        for record in payload.tasks where !taskIDs.contains(record.id) {
            context.insert(LumaTask(
                id: record.id,
                title: record.title,
                area: LifeArea(rawValue: record.areaRaw) ?? .errands,
                deadline: record.deadline,
                estimatedMinutes: record.estimatedMinutes,
                energy: EnergyLevel(rawValue: record.energyRaw) ?? .medium,
                impact: ImpactType(rawValue: record.impactRaw) ?? .general,
                academicWeight: record.academicWeight,
                academicSubjectID: record.academicSubjectID,
                subjectGradeItemID: record.subjectGradeItemID,
                grade: record.grade,
                status: TaskStatus(rawValue: record.statusRaw) ?? .pending,
                createdAt: record.createdAt,
                completedAt: record.completedAt,
                postponementCount: record.postponementCount,
                unlocksAnotherTask: record.unlocksAnotherTask,
                unlocksTaskID: record.unlocksTaskID,
                notes: record.notes,
                focusedMinutes: record.focusedMinutes,
                focusSessionCount: record.focusSessionCount,
                lastFocusedAt: record.lastFocusedAt
            ))
            restoredTasks += 1
        }

        for record in payload.sessions where !sessionIDs.contains(record.id) {
            context.insert(FocusSession(
                id: record.id,
                taskID: record.taskID,
                taskTitle: record.taskTitle,
                area: LifeArea(rawValue: record.areaRaw) ?? .errands,
                plannedMinutes: record.plannedMinutes,
                actualMinutes: record.actualMinutes,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                energyPreference: EnergyPreference(rawValue: record.energyPreferenceRaw) ?? .normal,
                completedTask: record.completedTask,
                ignoredFromLearning: record.ignoredFromLearning
            ))
            restoredSessions += 1
        }

        for record in payload.studyGuides ?? [] where !studyGuideIDs.contains(record.id) {
            context.insert(StudyGuide(
                id: record.id,
                title: record.title,
                sourceFileName: record.sourceFileName,
                importedAt: record.importedAt,
                examDate: record.examDate,
                pageCount: record.pageCount,
                overview: record.overview,
                generatedAt: record.generatedAt,
                generationVersion: record.generationVersion ?? 1,
                sourcePages: record.sourcePages,
                topics: record.topics,
                flashcards: record.flashcards,
                questions: record.questions,
                reviewTaskID: record.reviewTaskID
            ))
            restoredStudyGuides += 1
        }

        for record in payload.subjects ?? [] where !subjectIDs.contains(record.id) {
            context.insert(AcademicSubject(
                id: record.id,
                name: record.name,
                targetGrade: record.targetGrade,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                isArchived: record.isArchived
            ))
            restoredSubjects += 1
        }

        let availableSubjectIDs = subjectIDs.union((payload.subjects ?? []).map(\.id))
        for record in payload.subjectGradeItems ?? []
        where !subjectGradeItemIDs.contains(record.id) && availableSubjectIDs.contains(record.subjectID) {
            context.insert(SubjectGradeItem(
                id: record.id,
                subjectID: record.subjectID,
                title: record.title,
                weightPercent: record.weightPercent,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt,
                isArchived: record.isArchived
            ))
            restoredSubjectGradeItems += 1
        }
        try context.save()
        return (
            restoredTasks,
            restoredSessions,
            restoredStudyGuides,
            restoredSubjects,
            restoredSubjectGradeItems
        )
    }
}
