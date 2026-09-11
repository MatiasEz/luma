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
    var version = 2
    var exportedAt = Date.now
    var tasks: [TaskRecord]
    var sessions: [SessionRecord]
    var studyGuides: [StudyGuideRecord]? = nil
    var subjects: [SubjectRecord]? = nil
    var subjectGradeItems: [SubjectGradeItemRecord]? = nil

    var classes: [CloudClassMeeting]? = nil
    var routines: [CloudAcademicRoutine]? = nil
    var exams: [CloudAcademicExam]? = nil
    var contexts: [CloudDailyPlanningContext]? = nil
    var profiles: [CloudProfile]? = nil
    var messages: [CloudChatMessage]? = nil
    var replans: [CloudReplanRecord]? = nil
    var preferences: [String: Data]? = nil

    struct TaskRecord: Codable {
        var id: UUID
        var title: String
        var areaRaw: String
        var dueDate: Date?
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
        var updatedAt: Date?
        var completedAt: Date?
        var postponementCount: Int
        var unlocksAnotherTask: Bool
        var unlocksTaskID: UUID?
        var notes: String
        var focusedMinutes: Int
        var focusSessionCount: Int
        var lastFocusedAt: Date?
        var sourceTypeRaw: String? = nil
        var sourceID: UUID? = nil
        var sourceOccurrenceDate: Date? = nil
        var studyStageRaw: String? = nil
        var planningDetailsRaw: String? = nil
    }

    struct SessionRecord: Codable {
        var originRaw: String? = nil
        var updatedAt: Date? = nil
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
        var colorHex: String? = nil
        var syllabusRaw: String? = nil
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
    static let portablePreferenceKeys: Set<String> = [
        "lumaDailyPlanSnapshot", "lumaDailyAgendaSnapshot", "lumaDailyTimeBudget.v1", "lumaSharedPlan.v1",
        "lumaWeeklyAvailability", "lumaLearningEnabled", "lumaPreferredBlockOverride", "lumaOnboardingCompleted",
        "lumaRememberedPreferences.v1", "lumaActiveFocus.v1", "lumaFocusRainAmbience", "lumaFocusRainVolume", "lumaFocusRainEnabled"
    ]

    static func preferences(defaults: UserDefaults = .standard) -> [String: Data] {
        portablePreferenceKeys.reduce(into: [:]) { result, key in
            if let value = defaults.object(forKey: key),
               let data = try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0) { result[key] = data }
        }
    }

    static func restorePreferences(_ preferences: [String: Data], defaults: UserDefaults = .standard) throws {
        var decoded: [String: Any] = [:]
        for (key, data) in preferences where portablePreferenceKeys.contains(key) {
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let value = plist["value"] else { throw CocoaError(.fileReadCorruptFile) }
            decoded[key] = value
        }
        for (key, value) in decoded { defaults.set(value, forKey: key) }
    }

    static func preview(data: Data) throws -> LumaBackupPayload {
        guard data.count <= 100 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LumaBackupPayload.self, from: data)
        try validate(payload)
        return payload
    }

    private static func validate(_ payload: LumaBackupPayload) throws {
        guard (1...2).contains(payload.version),
              Set(payload.tasks.map(\.id)).count == payload.tasks.count,
              Set(payload.sessions.map(\.id)).count == payload.sessions.count,
              payload.tasks.allSatisfy({ $0.estimatedMinutes > 0 && $0.estimatedMinutes <= 100_000 && $0.focusedMinutes >= 0 }),
              payload.sessions.allSatisfy({ $0.actualMinutes >= 0 && $0.actualMinutes <= 1440 }) else { throw CocoaError(.fileReadCorruptFile) }
        let identityGroups: [[UUID]] = [payload.studyGuides?.map(\.id) ?? [], payload.subjects?.map(\.id) ?? [],
            payload.subjectGradeItems?.map(\.id) ?? [], payload.classes?.map(\.id) ?? [], payload.routines?.map(\.id) ?? [],
            payload.exams?.map(\.id) ?? [], payload.contexts?.map(\.id) ?? [], payload.profiles?.map(\.id) ?? [],
            payload.messages?.map(\.id) ?? [], payload.replans?.map(\.id) ?? []]
        guard identityGroups.allSatisfy({ Set($0).count == $0.count }) else { throw CocoaError(.fileReadCorruptFile) }
        for (key, data) in payload.preferences ?? [:] where portablePreferenceKeys.contains(key) {
            guard (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["value"] != nil else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    static func document(
        tasks: [LumaTask],
        sessions: [FocusSession],
        studyGuides: [StudyGuide] = [],
        subjects: [AcademicSubject] = [],
        subjectGradeItems: [SubjectGradeItem] = [],
        classMeetings: [SubjectClassMeeting] = [], routines: [AcademicRoutine] = [],
        exams: [AcademicExam] = [], dailyContexts: [DailyPlanningContext] = [],
        profiles: [LumaProfile] = [], messages: [LumaChatRecord] = [], replans: [LumaReplanRecord] = [],
        preferences: [String: Data] = [:]
    ) throws -> LumaBackupDocument {
        var payload = LumaBackupPayload(
            tasks: tasks.map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    areaRaw: $0.areaRaw,
                    dueDate: $0.dueDate,
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
                    updatedAt: $0.updatedAt,
                    completedAt: $0.completedAt,
                    postponementCount: $0.postponementCount,
                    unlocksAnotherTask: $0.unlocksAnotherTask,
                    unlocksTaskID: $0.unlocksTaskID,
                    notes: $0.notes,
                    focusedMinutes: $0.focusedMinutes,
                    focusSessionCount: $0.focusSessionCount,
                    lastFocusedAt: $0.lastFocusedAt,
                    sourceTypeRaw: $0.sourceTypeRaw, sourceID: $0.sourceID, sourceOccurrenceDate: $0.sourceOccurrenceDate,
                    studyStageRaw: $0.studyStageRaw, planningDetailsRaw: $0.planningDetailsRaw
                )
            },
            sessions: sessions.map {
                .init(
                    originRaw: $0.originRaw, updatedAt: $0.updatedAt,
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
                    colorHex: $0.colorHex, syllabusRaw: $0.syllabusRaw,
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
        // Reuse complete, typed entity records with a neutral owner, never an auth token.
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        payload.classes = classMeetings.map { CloudClassMeeting(local: $0, userID: owner, formatter: formatter) }
        payload.routines = routines.map { CloudAcademicRoutine(local: $0, userID: owner, formatter: formatter) }
        payload.exams = exams.map { CloudAcademicExam(local: $0, userID: owner, formatter: formatter) }
        payload.contexts = dailyContexts.map { CloudDailyPlanningContext(local: $0, userID: owner, formatter: formatter) }
        payload.profiles = profiles.map { CloudProfile(local: $0, userID: owner, formatter: formatter) }
        payload.messages = messages.map { CloudChatMessage(local: $0, userID: owner, formatter: formatter) }
        payload.replans = replans.map { CloudReplanRecord(local: $0, userID: owner, formatter: formatter) }
        payload.preferences = preferences.filter { portablePreferenceKeys.contains($0.key) }
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
        guard (1...2).contains(payload.version) else { throw CocoaError(.fileReadUnsupportedScheme) }

        try validate(payload)
        let context = ModelContext(context.container)
        context.autosaveEnabled = false
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
                dueDate: record.dueDate,
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
                updatedAt: record.updatedAt ?? record.createdAt,
                completedAt: record.completedAt,
                postponementCount: record.postponementCount,
                unlocksAnotherTask: record.unlocksAnotherTask,
                unlocksTaskID: record.unlocksTaskID,
                notes: record.notes,
                focusedMinutes: record.focusedMinutes,
                focusSessionCount: record.focusSessionCount,
                lastFocusedAt: record.lastFocusedAt,
                sourceTypeRaw: record.sourceTypeRaw, sourceID: record.sourceID, sourceOccurrenceDate: record.sourceOccurrenceDate,
                studyStageRaw: record.studyStageRaw, planningDetailsRaw: record.planningDetailsRaw
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
                ignoredFromLearning: record.ignoredFromLearning,
                origin: record.originRaw.flatMap(FocusSessionOrigin.init(rawValue:)) ?? .focus,
                updatedAt: record.updatedAt
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
                colorHex: record.colorHex ?? "#7779A8", syllabusRaw: record.syllabusRaw ?? "",
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let classesIDs = Set(try context.fetch(FetchDescriptor<SubjectClassMeeting>()).map(\.id))
        for record in payload.classes ?? [] where !classesIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
        let routinesIDs = Set(try context.fetch(FetchDescriptor<AcademicRoutine>()).map(\.id))
        for record in payload.routines ?? [] where !routinesIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
        let examsIDs = Set(try context.fetch(FetchDescriptor<AcademicExam>()).map(\.id))
        for record in payload.exams ?? [] where !examsIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
        let contextsIDs = Set(try context.fetch(FetchDescriptor<DailyPlanningContext>()).map(\.id))
        for record in payload.contexts ?? [] where !contextsIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
        let profilesIDs = Set(try context.fetch(FetchDescriptor<LumaProfile>()).map(\.id))
        for record in payload.profiles ?? [] where !profilesIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
        let messagesIDs = Set(try context.fetch(FetchDescriptor<LumaChatRecord>()).map(\.id))
        for record in payload.messages ?? [] where !messagesIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
        let replansIDs = Set(try context.fetch(FetchDescriptor<LumaReplanRecord>()).map(\.id))
        for record in payload.replans ?? [] where !replansIDs.contains(record.id) { context.insert(record.local(formatter: formatter)) }
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
