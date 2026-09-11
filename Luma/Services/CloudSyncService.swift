import Foundation
import Observation
import Supabase
import SwiftData

private enum LumaCloudConfiguration {
    static let projectURL = "https://otzefpzacufwyerqsfct.supabase.co"
    static let publishableKey = "sb_publishable_nxXXMkg1lU5G14rkEwwELQ_JxoTGddU"
}

enum CloudSyncState: Equatable {
    case unconfigured
    case offline
    case connecting
    case syncing
    case synced
    case failed(String)

    var title: String {
        switch self {
        case .unconfigured: "Supabase pendiente de conectar"
        case .offline: "Sin conexión · datos seguros en esta Mac"
        case .connecting: "Conectando con la nube…"
        case .syncing: "Guardando cambios…"
        case .synced: "Datos sincronizados"
        case .failed: "La sincronización necesita atención"
        }
    }

    var isBusy: Bool {
        self == .connecting || self == .syncing
    }
}

@MainActor
@Observable
final class CloudSyncService {
    private static let pendingTaskDeletionKey = "luma.cloud.pendingTaskDeletionIDs"

    private let client: SupabaseClient?
    private let isoFormatter = ISO8601DateFormatter()

    private(set) var state: CloudSyncState
    private(set) var lastSyncedAt: Date?
    private(set) var userID: UUID?
    private(set) var lastErrorMessage: String?

    init(bundle: Bundle = .main) {
        let rawURL = bundle.object(forInfoDictionaryKey: "LUMA_SUPABASE_URL") as? String
            ?? LumaCloudConfiguration.projectURL
        let key = bundle.object(forInfoDictionaryKey: "LUMA_SUPABASE_PUBLISHABLE_KEY") as? String
            ?? LumaCloudConfiguration.publishableKey
        if let url = URL(string: rawURL), !rawURL.isEmpty, !key.isEmpty {
            client = SupabaseClient(
                supabaseURL: url,
                supabaseKey: key,
                options: SupabaseClientOptions(
                    auth: .init(
                        storage: LumaAuthStorage.current,
                        emitLocalSessionAsInitialSession: true
                    )
                )
            )
            state = .offline
        } else {
            client = nil
            state = .unconfigured
        }
    }

    var isConfigured: Bool { client != nil }

    /// Keeps deletions durable while the Mac is offline so a remote copy cannot
    /// resurrect the task during the next pull.
    func queueTaskDeletion(_ taskID: UUID) {
        var pending = pendingTaskDeletionIDs
        pending.insert(taskID)
        savePendingTaskDeletionIDs(pending)
    }

    func cancelTaskDeletion(_ taskID: UUID) {
        var pending = pendingTaskDeletionIDs
        pending.remove(taskID)
        savePendingTaskDeletionIDs(pending)
    }

    func sync(
        tasks: [LumaTask],
        sessions: [FocusSession],
        profiles: [LumaProfile],
        messages: [LumaChatRecord],
        replans: [LumaReplanRecord],
        subjects: [AcademicSubject],
        subjectGradeItems: [SubjectGradeItem],
        classMeetings: [SubjectClassMeeting] = [],
        routines: [AcademicRoutine] = [],
        exams: [AcademicExam] = [],
        dailyContexts: [DailyPlanningContext] = [],
        context: ModelContext
    ) async {
        guard let client else {
            print("⚠️ [CLOUD-SYNC] Supabase no está configurado")
            state = .unconfigured
            return
        }
        guard !state.isBusy else {
            print("⏭️ [CLOUD-SYNC] Sincronización omitida: ya hay otra en curso")
            return
        }

        print(
            "☁️ [CLOUD-SYNC] Inicio | tareas=\(tasks.count) | sesiones=\(sessions.count) | " +
            "materias=\(subjects.count) | horarios=\(classMeetings.count) | rutinas=\(routines.count) | " +
            "exámenes=\(exams.count) | contextos=\(dailyContexts.count)"
        )

        // A previous interrupted pull can leave two SwiftData objects with the same
        // logical UUID. Dictionary(uniqueKeysWithValues:) would terminate the app
        // before the sync error handler gets a chance to report it, so repair those
        // collisions first and continue with one canonical object per cloud row.
        let uniqueTasks = repairDuplicateModels(
            tasks,
            table: "tasks",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueSessions = repairDuplicateModels(
            sessions,
            table: "focus_sessions",
            id: \.id,
            updatedAt: \.endedAt,
            context: context
        )
        let uniqueProfiles = repairDuplicateModels(
            profiles,
            table: "profiles",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueMessages = repairDuplicateModels(
            messages,
            table: "chat_messages",
            id: \.id,
            updatedAt: \.createdAt,
            context: context
        )
        let uniqueReplans = repairDuplicateModels(
            replans,
            table: "replan_records",
            id: \.id,
            updatedAt: \.createdAt,
            context: context
        )
        let uniqueSubjects = repairDuplicateModels(
            subjects,
            table: "academic_subjects",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueGradeItems = repairDuplicateModels(
            subjectGradeItems,
            table: "subject_grade_items",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueClassMeetings = repairDuplicateModels(
            classMeetings,
            table: "subject_class_meetings",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueRoutines = repairDuplicateModels(
            routines,
            table: "academic_routines",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueExams = repairDuplicateModels(
            exams,
            table: "academic_exams",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )
        let uniqueDailyContexts = repairDuplicateModels(
            dailyContexts,
            table: "daily_planning_contexts",
            id: \.id,
            updatedAt: \.updatedAt,
            context: context
        )

        do {
            state = .connecting
            let userID = try await loggedSyncStep("AUTH sesión") {
                try await authenticatedUserID(using: client)
            }
            self.userID = userID
            print("🔐 [CLOUD-SYNC] Usuario autenticado | id=\(userID.uuidString.prefix(8))…")
            state = .syncing

            try await loggedSyncStep("DELETE tareas pendientes | cantidad=\(pendingTaskDeletionIDs.count)") {
                try await flushPendingTaskDeletions(userID: userID, client: client)
            }

            try await loggedSyncStep("PULL remoto completo") {
                try await pullRemoteData(
                    userID: userID,
                    client: client,
                    tasks: uniqueTasks,
                    sessions: uniqueSessions,
                    profiles: uniqueProfiles,
                    messages: uniqueMessages,
                    replans: uniqueReplans,
                    subjects: uniqueSubjects,
                    subjectGradeItems: uniqueGradeItems,
                    classMeetings: uniqueClassMeetings,
                    routines: uniqueRoutines,
                    exams: uniqueExams,
                    dailyContexts: uniqueDailyContexts,
                    context: context
                )
            }
            try await loggedSyncStep("PUSH local completo") {
                try await pushLocalData(
                    userID: userID,
                    client: client,
                    tasks: uniqueTasks,
                    sessions: uniqueSessions,
                    profiles: uniqueProfiles,
                    messages: uniqueMessages,
                    replans: uniqueReplans,
                    subjects: uniqueSubjects,
                    subjectGradeItems: uniqueGradeItems,
                    classMeetings: uniqueClassMeetings,
                    routines: uniqueRoutines,
                    exams: uniqueExams,
                    dailyContexts: uniqueDailyContexts
                )
            }
            try await loggedSyncStep("SAVE caché local") {
                try context.save()
            }
            lastSyncedAt = .now
            lastErrorMessage = nil
            state = .synced
            print("✅ [CLOUD-SYNC] Sincronización finalizada")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            print("📴 [CLOUD-SYNC] Sin conexión | \(detailedError(error))")
            state = .offline
        } catch {
            lastErrorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
            print("❌ [CLOUD-SYNC] Falló la sincronización | \(detailedError(error))")
        }
    }

    private func loggedSyncStep<Value>(
        _ name: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        let startedAt = Date()
        print("▶️ [CLOUD-SYNC] \(name)")
        do {
            let value = try await operation()
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
            print("✅ [CLOUD-SYNC] \(name) | \(elapsed)s")
            return value
        } catch {
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
            print("❌ [CLOUD-SYNC] \(name) | \(elapsed)s | \(detailedError(error))")
            throw error
        }
    }

    private func detailedError(_ error: Error) -> String {
        "tipo=\(String(describing: type(of: error))) | mensaje=\(error.localizedDescription) | detalle=\(String(reflecting: error))"
    }

    private func repairDuplicateModels<Model: PersistentModel>(
        _ models: [Model],
        table: String,
        id: KeyPath<Model, UUID>,
        updatedAt: KeyPath<Model, Date>,
        context: ModelContext
    ) -> [Model] {
        var canonicalByID: [UUID: (model: Model, originalIndex: Int)] = [:]
        var duplicateIDs = Set<UUID>()
        var deletedObjectIDs = Set<PersistentIdentifier>()

        for (index, model) in models.enumerated() {
            let logicalID = model[keyPath: id]
            guard let existing = canonicalByID[logicalID] else {
                canonicalByID[logicalID] = (model, index)
                continue
            }

            duplicateIDs.insert(logicalID)
            let incomingIsNewer = model[keyPath: updatedAt] > existing.model[keyPath: updatedAt]
            let canonical = incomingIsNewer ? model : existing.model
            let duplicate = incomingIsNewer ? existing.model : model
            canonicalByID[logicalID] = (canonical, existing.originalIndex)

            // The same object can occasionally be repeated in an input array. Only
            // delete when these are actually two different SwiftData records.
            let duplicateObjectID = duplicate.persistentModelID
            if duplicateObjectID != canonical.persistentModelID,
               deletedObjectIDs.insert(duplicateObjectID).inserted {
                context.delete(duplicate)
            }
        }

        if !duplicateIDs.isEmpty {
            let ids = duplicateIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ", ")
            print(
                "⚠️ [CLOUD-SYNC] Duplicados locales reparados | tabla=\(table) | " +
                "cantidad=\(duplicateIDs.count) | ids=\(ids)"
            )
        }

        return canonicalByID.values
            .sorted { $0.originalIndex < $1.originalIndex }
            .map(\.model)
    }

    private func authenticatedUserID(using client: SupabaseClient) async throws -> UUID {
        if let current = try? await client.auth.session.user.id {
            return current
        }
        return try await client.auth.signInAnonymously().user.id
    }

    private var pendingTaskDeletionIDs: Set<UUID> {
        let stored = UserDefaults.standard.stringArray(forKey: Self.pendingTaskDeletionKey) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    private func savePendingTaskDeletionIDs(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: Self.pendingTaskDeletionKey)
    }

    private func flushPendingTaskDeletions(userID: UUID, client: SupabaseClient) async throws {
        for taskID in pendingTaskDeletionIDs {
            try await client
                .from("tasks")
                .delete()
                .eq("id", value: taskID)
                .eq("user_id", value: userID)
                .execute()

            var remaining = pendingTaskDeletionIDs
            remaining.remove(taskID)
            savePendingTaskDeletionIDs(remaining)
        }
    }

    private func pushLocalData(
        userID: UUID,
        client: SupabaseClient,
        tasks: [LumaTask],
        sessions: [FocusSession],
        profiles: [LumaProfile],
        messages: [LumaChatRecord],
        replans: [LumaReplanRecord],
        subjects: [AcademicSubject],
        subjectGradeItems: [SubjectGradeItem],
        classMeetings: [SubjectClassMeeting],
        routines: [AcademicRoutine],
        exams: [AcademicExam],
        dailyContexts: [DailyPlanningContext]
    ) async throws {
        if !tasks.isEmpty {
            try await loggedSyncStep("PUSH tasks | cantidad=\(tasks.count)") {
                try await client.from("tasks").upsert(tasks.map { CloudTask(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !sessions.isEmpty {
            try await loggedSyncStep("PUSH focus_sessions | cantidad=\(sessions.count)") {
                try await client.from("focus_sessions").upsert(sessions.map { CloudFocusSession(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !profiles.isEmpty {
            try await loggedSyncStep("PUSH profiles | cantidad=\(profiles.count)") {
                try await client.from("profiles").upsert(profiles.map { CloudProfile(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !messages.isEmpty {
            try await loggedSyncStep("PUSH chat_messages | cantidad=\(messages.count)") {
                try await client.from("chat_messages").upsert(messages.map { CloudChatMessage(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !replans.isEmpty {
            try await loggedSyncStep("PUSH replan_records | cantidad=\(replans.count)") {
                try await client.from("replan_records").upsert(replans.map { CloudReplanRecord(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !subjects.isEmpty {
            try await loggedSyncStep("PUSH academic_subjects | cantidad=\(subjects.count)") {
                try await client.from("academic_subjects").upsert(subjects.map { CloudAcademicSubject(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !subjectGradeItems.isEmpty {
            try await loggedSyncStep("PUSH subject_grade_items | cantidad=\(subjectGradeItems.count)") {
                try await client.from("subject_grade_items").upsert(subjectGradeItems.map { CloudSubjectGradeItem(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !classMeetings.isEmpty {
            try await loggedSyncStep("PUSH subject_class_meetings | cantidad=\(classMeetings.count)") {
                try await client.from("subject_class_meetings").upsert(classMeetings.map { CloudClassMeeting(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !routines.isEmpty {
            try await loggedSyncStep("PUSH academic_routines | cantidad=\(routines.count)") {
                try await client.from("academic_routines").upsert(routines.map { CloudAcademicRoutine(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !exams.isEmpty {
            try await loggedSyncStep("PUSH academic_exams | cantidad=\(exams.count)") {
                try await client.from("academic_exams").upsert(exams.map { CloudAcademicExam(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
        if !dailyContexts.isEmpty {
            try await loggedSyncStep("PUSH daily_planning_contexts | cantidad=\(dailyContexts.count)") {
                try await client.from("daily_planning_contexts").upsert(dailyContexts.map { CloudDailyPlanningContext(local: $0, userID: userID, formatter: isoFormatter) }).execute()
            }
        }
    }

    private func pullRemoteData(
        userID: UUID,
        client: SupabaseClient,
        tasks: [LumaTask],
        sessions: [FocusSession],
        profiles: [LumaProfile],
        messages: [LumaChatRecord],
        replans: [LumaReplanRecord],
        subjects: [AcademicSubject],
        subjectGradeItems: [SubjectGradeItem],
        classMeetings: [SubjectClassMeeting],
        routines: [AcademicRoutine],
        exams: [AcademicExam],
        dailyContexts: [DailyPlanningContext],
        context: ModelContext
    ) async throws {
        let remoteTasks: [CloudTask] = try await loggedSyncStep("PULL tasks") {
            try await client.from("tasks").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL tasks | recibidos=\(remoteTasks.count)")
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for record in remoteTasks {
            if let local = tasksByID[record.id] {
                if record.updatedDate(formatter: isoFormatter) > local.updatedAt {
                    record.apply(to: local, formatter: isoFormatter)
                }
            } else {
                context.insert(record.local(formatter: isoFormatter))
            }
        }

        let remoteSessions: [CloudFocusSession] = try await loggedSyncStep("PULL focus_sessions") {
            try await client.from("focus_sessions").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL focus_sessions | recibidos=\(remoteSessions.count)")
        let sessionIDs = Set(sessions.map(\.id))
        for record in remoteSessions where !sessionIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteProfiles: [CloudProfile] = try await loggedSyncStep("PULL profiles") {
            try await client.from("profiles").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL profiles | recibidos=\(remoteProfiles.count)")
        let profileIDs = Set(profiles.map(\.id))
        for record in remoteProfiles where !profileIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteMessages: [CloudChatMessage] = try await loggedSyncStep("PULL chat_messages") {
            try await client.from("chat_messages").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL chat_messages | recibidos=\(remoteMessages.count)")
        let messageIDs = Set(messages.map(\.id))
        for record in remoteMessages where !messageIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteReplans: [CloudReplanRecord] = try await loggedSyncStep("PULL replan_records") {
            try await client.from("replan_records").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL replan_records | recibidos=\(remoteReplans.count)")
        let replanIDs = Set(replans.map(\.id))
        for record in remoteReplans where !replanIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteSubjects: [CloudAcademicSubject] = try await loggedSyncStep("PULL academic_subjects") {
            try await client.from("academic_subjects").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL academic_subjects | recibidos=\(remoteSubjects.count)")
        let subjectsByID = Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0) })
        for record in remoteSubjects {
            if let local = subjectsByID[record.id] {
                let remoteUpdated = isoFormatter.date(from: record.updatedAt) ?? .distantPast
                if remoteUpdated > local.updatedAt {
                    local.name = record.name
                    local.targetGrade = record.targetGrade
                    local.colorHex = record.colorHex
                    local.syllabusRaw = record.syllabusRaw
                    local.updatedAt = remoteUpdated
                    local.isArchived = record.isArchived
                }
            } else {
                context.insert(record.local(formatter: isoFormatter))
            }
        }

        let remoteGradeItems: [CloudSubjectGradeItem] = try await loggedSyncStep("PULL subject_grade_items") {
            try await client.from("subject_grade_items").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL subject_grade_items | recibidos=\(remoteGradeItems.count)")
        let itemsByID = Dictionary(uniqueKeysWithValues: subjectGradeItems.map { ($0.id, $0) })
        for record in remoteGradeItems {
            if let local = itemsByID[record.id] {
                let remoteUpdated = isoFormatter.date(from: record.updatedAt) ?? .distantPast
                if remoteUpdated > local.updatedAt {
                    local.subjectID = record.subjectID
                    local.title = record.title
                    local.weightPercent = record.weightPercent
                    local.updatedAt = remoteUpdated
                    local.isArchived = record.isArchived
                }
            } else {
                context.insert(record.local(formatter: isoFormatter))
            }
        }

        let remoteMeetings: [CloudClassMeeting] = try await loggedSyncStep("PULL subject_class_meetings") {
            try await client.from("subject_class_meetings").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL subject_class_meetings | recibidos=\(remoteMeetings.count)")
        let meetingsByID = Dictionary(uniqueKeysWithValues: classMeetings.map { ($0.id, $0) })
        for record in remoteMeetings {
            if let local = meetingsByID[record.id] { record.apply(to: local, formatter: isoFormatter) }
            else { context.insert(record.local(formatter: isoFormatter)) }
        }

        let remoteRoutines: [CloudAcademicRoutine] = try await loggedSyncStep("PULL academic_routines") {
            try await client.from("academic_routines").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL academic_routines | recibidos=\(remoteRoutines.count)")
        let routinesByID = Dictionary(uniqueKeysWithValues: routines.map { ($0.id, $0) })
        for record in remoteRoutines {
            if let local = routinesByID[record.id] { record.apply(to: local, formatter: isoFormatter) }
            else { context.insert(record.local(formatter: isoFormatter)) }
        }

        let remoteExams: [CloudAcademicExam] = try await loggedSyncStep("PULL academic_exams") {
            try await client.from("academic_exams").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL academic_exams | recibidos=\(remoteExams.count)")
        let examsByID = Dictionary(uniqueKeysWithValues: exams.map { ($0.id, $0) })
        for record in remoteExams {
            if let local = examsByID[record.id] { record.apply(to: local, formatter: isoFormatter) }
            else { context.insert(record.local(formatter: isoFormatter)) }
        }

        let remoteContexts: [CloudDailyPlanningContext] = try await loggedSyncStep("PULL daily_planning_contexts") {
            try await client.from("daily_planning_contexts").select().eq("user_id", value: userID).execute().value
        }
        print("📥 [CLOUD-SYNC] PULL daily_planning_contexts | recibidos=\(remoteContexts.count)")
        let contextsByID = Dictionary(uniqueKeysWithValues: dailyContexts.map { ($0.id, $0) })
        for record in remoteContexts {
            if let local = contextsByID[record.id] { record.apply(to: local, formatter: isoFormatter) }
            else { context.insert(record.local(formatter: isoFormatter)) }
        }
    }
}

private struct CloudAcademicSubject: Codable {
    let id: UUID
    let userID: UUID
    let name: String
    let targetGrade: Double?
    let colorHex: String
    let syllabusRaw: String
    let createdAt: String
    let updatedAt: String
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case userID = "user_id"
        case targetGrade = "target_grade"
        case colorHex = "color_hex"
        case syllabusRaw = "syllabus_raw"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isArchived = "is_archived"
    }

    init(local: AcademicSubject, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        name = local.name
        targetGrade = local.targetGrade
        colorHex = local.colorHex
        syllabusRaw = local.syllabusRaw
        createdAt = formatter.string(from: local.createdAt)
        updatedAt = formatter.string(from: local.updatedAt)
        isArchived = local.isArchived
    }

    func local(formatter: ISO8601DateFormatter) -> AcademicSubject {
        AcademicSubject(
            id: id,
            name: name,
            targetGrade: targetGrade,
            colorHex: colorHex,
            syllabusRaw: syllabusRaw,
            createdAt: formatter.date(from: createdAt) ?? .now,
            updatedAt: formatter.date(from: updatedAt) ?? .now,
            isArchived: isArchived
        )
    }
}

private struct CloudSubjectGradeItem: Codable {
    let id: UUID
    let userID: UUID
    let subjectID: UUID
    let title: String
    let weightPercent: Double
    let createdAt: String
    let updatedAt: String
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, title
        case userID = "user_id"
        case subjectID = "subject_id"
        case weightPercent = "weight_percent"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isArchived = "is_archived"
    }

    init(local: SubjectGradeItem, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        subjectID = local.subjectID
        title = local.title
        weightPercent = local.weightPercent
        createdAt = formatter.string(from: local.createdAt)
        updatedAt = formatter.string(from: local.updatedAt)
        isArchived = local.isArchived
    }

    func local(formatter: ISO8601DateFormatter) -> SubjectGradeItem {
        SubjectGradeItem(
            id: id,
            subjectID: subjectID,
            title: title,
            weightPercent: weightPercent,
            createdAt: formatter.date(from: createdAt) ?? .now,
            updatedAt: formatter.date(from: updatedAt) ?? .now,
            isArchived: isArchived
        )
    }
}

private struct CloudClassMeeting: Codable {
    let id: UUID
    let userID: UUID
    let subjectID: UUID
    let weekday: Int
    let startMinuteOfDay: Int
    let endMinuteOfDay: Int
    let location: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, weekday, location
        case userID = "user_id"
        case subjectID = "subject_id"
        case startMinuteOfDay = "start_minute_of_day"
        case endMinuteOfDay = "end_minute_of_day"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(local: SubjectClassMeeting, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id; self.userID = userID; subjectID = local.subjectID; weekday = local.weekday
        startMinuteOfDay = local.startMinuteOfDay; endMinuteOfDay = local.endMinuteOfDay
        location = local.location; createdAt = formatter.string(from: local.createdAt); updatedAt = formatter.string(from: local.updatedAt)
    }

    func local(formatter: ISO8601DateFormatter) -> SubjectClassMeeting {
        SubjectClassMeeting(id: id, subjectID: subjectID, weekday: weekday, startMinuteOfDay: startMinuteOfDay, endMinuteOfDay: endMinuteOfDay, location: location, createdAt: formatter.date(from: createdAt) ?? .now, updatedAt: formatter.date(from: updatedAt) ?? .now)
    }

    func apply(to local: SubjectClassMeeting, formatter: ISO8601DateFormatter) {
        guard (formatter.date(from: updatedAt) ?? .distantPast) > local.updatedAt else { return }
        local.subjectID = subjectID; local.weekday = weekday; local.startMinuteOfDay = startMinuteOfDay
        local.endMinuteOfDay = endMinuteOfDay; local.location = location; local.updatedAt = formatter.date(from: updatedAt) ?? .now
    }
}

private struct CloudAcademicRoutine: Codable {
    let id: UUID
    let userID: UUID
    let title: String
    let subjectID: UUID?
    let weekday: Int
    let minuteOfDay: Int?
    let activityType: String
    let estimatedMinutes: Int
    let startDate: String
    let endDate: String?
    let isPaused: Bool
    let pauseDuringVacation: Bool
    let notes: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, weekday, notes
        case userID = "user_id"; case subjectID = "subject_id"; case minuteOfDay = "minute_of_day"
        case activityType = "activity_type"; case estimatedMinutes = "estimated_minutes"
        case startDate = "start_date"; case endDate = "end_date"; case isPaused = "is_paused"
        case pauseDuringVacation = "pause_during_vacation"; case createdAt = "created_at"; case updatedAt = "updated_at"
    }

    init(local: AcademicRoutine, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id; self.userID = userID; title = local.title; subjectID = local.subjectID; weekday = local.weekday
        minuteOfDay = local.minuteOfDay; activityType = local.activityTypeRaw; estimatedMinutes = local.estimatedMinutes
        startDate = formatter.string(from: local.startDate); endDate = local.endDate.map(formatter.string(from:))
        isPaused = local.isPaused; pauseDuringVacation = local.pauseDuringVacation; notes = local.notes
        createdAt = formatter.string(from: local.createdAt); updatedAt = formatter.string(from: local.updatedAt)
    }

    func local(formatter: ISO8601DateFormatter) -> AcademicRoutine {
        AcademicRoutine(id: id, title: title, subjectID: subjectID, weekday: weekday, minuteOfDay: minuteOfDay, activityType: AcademicActivityType(rawValue: activityType) ?? .assignment, estimatedMinutes: estimatedMinutes, startDate: formatter.date(from: startDate) ?? .now, endDate: endDate.flatMap(formatter.date(from:)), isPaused: isPaused, pauseDuringVacation: pauseDuringVacation, notes: notes, createdAt: formatter.date(from: createdAt) ?? .now, updatedAt: formatter.date(from: updatedAt) ?? .now)
    }

    func apply(to local: AcademicRoutine, formatter: ISO8601DateFormatter) {
        guard (formatter.date(from: updatedAt) ?? .distantPast) > local.updatedAt else { return }
        local.title = title; local.subjectID = subjectID; local.weekday = weekday; local.minuteOfDay = minuteOfDay
        local.activityTypeRaw = activityType; local.estimatedMinutes = estimatedMinutes; local.startDate = formatter.date(from: startDate) ?? local.startDate
        local.endDate = endDate.flatMap(formatter.date(from:)); local.isPaused = isPaused; local.pauseDuringVacation = pauseDuringVacation
        local.notes = notes; local.updatedAt = formatter.date(from: updatedAt) ?? .now
    }
}

private struct CloudAcademicExam: Codable {
    let id: UUID
    let userID: UUID
    let title: String
    let subjectID: UUID
    let date: String
    let topicsRaw: String
    let importance: String
    let preparationMinutes: Int
    let isArchived: Bool
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, date, importance
        case userID = "user_id"; case subjectID = "subject_id"; case topicsRaw = "topics_raw"
        case preparationMinutes = "preparation_minutes"; case isArchived = "is_archived"
        case createdAt = "created_at"; case updatedAt = "updated_at"
    }

    init(local: AcademicExam, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id; self.userID = userID; title = local.title; subjectID = local.subjectID
        date = formatter.string(from: local.date); topicsRaw = local.topicsRaw; importance = local.importanceRaw
        preparationMinutes = local.preparationMinutes; isArchived = local.isArchived
        createdAt = formatter.string(from: local.createdAt); updatedAt = formatter.string(from: local.updatedAt)
    }

    func local(formatter: ISO8601DateFormatter) -> AcademicExam {
        AcademicExam(id: id, title: title, subjectID: subjectID, date: formatter.date(from: date) ?? .now, topicsRaw: topicsRaw, importance: ExamImportance(rawValue: importance) ?? .important, preparationMinutes: preparationMinutes, isArchived: isArchived, createdAt: formatter.date(from: createdAt) ?? .now, updatedAt: formatter.date(from: updatedAt) ?? .now)
    }

    func apply(to local: AcademicExam, formatter: ISO8601DateFormatter) {
        guard (formatter.date(from: updatedAt) ?? .distantPast) > local.updatedAt else { return }
        local.title = title; local.subjectID = subjectID; local.date = formatter.date(from: date) ?? local.date
        local.topicsRaw = topicsRaw; local.importanceRaw = importance; local.preparationMinutes = preparationMinutes
        local.isArchived = isArchived; local.updatedAt = formatter.date(from: updatedAt) ?? .now
    }
}

private struct CloudDailyPlanningContext: Codable {
    let id: UUID
    let userID: UUID
    let day: String
    let energy: String
    let availableMinutes: Int
    let planningMode: String
    let restCounts: Bool
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, day, energy
        case userID = "user_id"; case availableMinutes = "available_minutes"
        case planningMode = "planning_mode"; case restCounts = "rest_counts"; case updatedAt = "updated_at"
    }

    init(local: DailyPlanningContext, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id; self.userID = userID; day = formatter.string(from: local.day); energy = local.energyRaw
        availableMinutes = local.availableMinutes; planningMode = local.planningModeRaw; restCounts = local.restCounts
        updatedAt = formatter.string(from: local.updatedAt)
    }

    func local(formatter: ISO8601DateFormatter) -> DailyPlanningContext {
        DailyPlanningContext(id: id, day: formatter.date(from: day) ?? .now, energy: EnergyPreference(rawValue: energy) ?? .normal, availableMinutes: availableMinutes, planningMode: PlanningMode(rawValue: planningMode) ?? .realistic, restCounts: restCounts, updatedAt: formatter.date(from: updatedAt) ?? .now)
    }

    func apply(to local: DailyPlanningContext, formatter: ISO8601DateFormatter) {
        guard (formatter.date(from: updatedAt) ?? .distantPast) > local.updatedAt else { return }
        local.day = formatter.date(from: day) ?? local.day; local.energyRaw = energy; local.availableMinutes = availableMinutes
        local.planningModeRaw = planningMode; local.restCounts = restCounts; local.updatedAt = formatter.date(from: updatedAt) ?? .now
    }
}

private struct CloudTask: Codable {
    let id: UUID
    let userID: UUID
    let title: String
    let area: String
    let dueDate: String?
    let deadline: String?
    let estimatedMinutes: Int
    let energy: String
    let impact: String
    let academicWeight: Double?
    let academicSubjectID: UUID?
    let subjectGradeItemID: UUID?
    let grade: Double?
    let status: String
    let createdAt: String
    let completedAt: String?
    let postponementCount: Int
    let unlocksAnotherTask: Bool
    let unlocksTaskID: UUID?
    let notes: String
    let focusedMinutes: Int
    let focusSessionCount: Int
    let lastFocusedAt: String?
    let updatedAt: String
    let sourceType: String?
    let sourceID: UUID?
    let sourceOccurrenceDate: String?
    let studyStage: String?

    enum CodingKeys: String, CodingKey {
        case id, title, area, deadline, energy, impact, status, notes
        case userID = "user_id"
        case dueDate = "due_date"
        case estimatedMinutes = "estimated_minutes"
        case academicWeight = "academic_weight"
        case academicSubjectID = "academic_subject_id"
        case subjectGradeItemID = "subject_grade_item_id"
        case grade
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case postponementCount = "postponement_count"
        case unlocksAnotherTask = "unlocks_another_task"
        case unlocksTaskID = "unlocks_task_id"
        case focusedMinutes = "focused_minutes"
        case focusSessionCount = "focus_session_count"
        case lastFocusedAt = "last_focused_at"
        case updatedAt = "updated_at"
        case sourceType = "source_type"
        case sourceID = "source_id"
        case sourceOccurrenceDate = "source_occurrence_date"
        case studyStage = "study_stage"
    }

    init(local: LumaTask, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        title = local.title
        area = local.areaRaw
        dueDate = local.dueDate.map(formatter.string(from:))
        deadline = local.deadline.map(formatter.string(from:))
        estimatedMinutes = local.estimatedMinutes
        energy = local.energyRaw
        impact = local.impactRaw
        academicWeight = local.academicWeight
        academicSubjectID = local.academicSubjectID
        subjectGradeItemID = local.subjectGradeItemID
        grade = local.grade
        status = local.statusRaw
        createdAt = formatter.string(from: local.createdAt)
        completedAt = local.completedAt.map(formatter.string(from:))
        postponementCount = local.postponementCount
        unlocksAnotherTask = local.unlocksAnotherTask
        unlocksTaskID = local.unlocksTaskID
        notes = local.notes
        focusedMinutes = local.focusedMinutes
        focusSessionCount = local.focusSessionCount
        lastFocusedAt = local.lastFocusedAt.map(formatter.string(from:))
        updatedAt = formatter.string(from: local.updatedAt)
        sourceType = local.sourceTypeRaw
        sourceID = local.sourceID
        sourceOccurrenceDate = local.sourceOccurrenceDate.map(formatter.string(from:))
        studyStage = local.studyStageRaw
    }

    func local(formatter: ISO8601DateFormatter) -> LumaTask {
        LumaTask(
            id: id,
            title: title,
            area: LifeArea(rawValue: area) ?? .errands,
            dueDate: dueDate.flatMap(formatter.date(from:)),
            deadline: deadline.flatMap(formatter.date(from:)),
            estimatedMinutes: estimatedMinutes,
            energy: EnergyLevel(rawValue: energy) ?? .medium,
            impact: ImpactType(rawValue: impact) ?? .general,
            academicWeight: academicWeight,
            academicSubjectID: academicSubjectID,
            subjectGradeItemID: subjectGradeItemID,
            grade: grade,
            status: TaskStatus(rawValue: status) ?? .pending,
            createdAt: formatter.date(from: createdAt) ?? .now,
            updatedAt: formatter.date(from: updatedAt) ?? formatter.date(from: createdAt) ?? .now,
            completedAt: completedAt.flatMap(formatter.date(from:)),
            postponementCount: postponementCount,
            unlocksAnotherTask: unlocksAnotherTask,
            unlocksTaskID: unlocksTaskID,
            notes: notes,
            focusedMinutes: focusedMinutes,
            focusSessionCount: focusSessionCount,
            lastFocusedAt: lastFocusedAt.flatMap(formatter.date(from:)),
            sourceTypeRaw: sourceType,
            sourceID: sourceID,
            sourceOccurrenceDate: sourceOccurrenceDate.flatMap(formatter.date(from:)),
            studyStageRaw: studyStage
        )
    }

    func updatedDate(formatter: ISO8601DateFormatter) -> Date {
        formatter.date(from: updatedAt) ?? formatter.date(from: createdAt) ?? .distantPast
    }

    func apply(to local: LumaTask, formatter: ISO8601DateFormatter) {
        local.title = title
        local.areaRaw = area
        local.dueDate = dueDate.flatMap(formatter.date(from:))
        local.deadline = deadline.flatMap(formatter.date(from:))
        local.estimatedMinutes = estimatedMinutes
        local.energyRaw = energy
        local.impactRaw = impact
        local.academicWeight = academicWeight
        local.academicSubjectID = academicSubjectID
        local.subjectGradeItemID = subjectGradeItemID
        local.grade = grade
        local.statusRaw = status
        local.completedAt = completedAt.flatMap(formatter.date(from:))
        local.postponementCount = postponementCount
        local.unlocksAnotherTask = unlocksAnotherTask
        local.unlocksTaskID = unlocksTaskID
        local.notes = notes
        local.focusedMinutes = focusedMinutes
        local.focusSessionCount = focusSessionCount
        local.lastFocusedAt = lastFocusedAt.flatMap(formatter.date(from:))
        local.updatedAt = updatedDate(formatter: formatter)
        local.sourceTypeRaw = sourceType
        local.sourceID = sourceID
        local.sourceOccurrenceDate = sourceOccurrenceDate.flatMap(formatter.date(from:))
        local.studyStageRaw = studyStage
    }
}

private struct CloudFocusSession: Codable {
    let id: UUID
    let userID: UUID
    let taskID: UUID
    let taskTitle: String
    let area: String
    let plannedMinutes: Int
    let actualMinutes: Int
    let startedAt: String
    let endedAt: String
    let energyPreference: String
    let completedTask: Bool
    let ignoredFromLearning: Bool

    enum CodingKeys: String, CodingKey {
        case id, area
        case userID = "user_id"
        case taskID = "task_id"
        case taskTitle = "task_title"
        case plannedMinutes = "planned_minutes"
        case actualMinutes = "actual_minutes"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case energyPreference = "energy_preference"
        case completedTask = "completed_task"
        case ignoredFromLearning = "ignored_from_learning"
    }

    init(local: FocusSession, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        taskID = local.taskID
        taskTitle = local.taskTitle
        area = local.areaRaw
        plannedMinutes = local.plannedMinutes
        actualMinutes = local.actualMinutes
        startedAt = formatter.string(from: local.startedAt)
        endedAt = formatter.string(from: local.endedAt)
        energyPreference = local.energyPreferenceRaw
        completedTask = local.completedTask
        ignoredFromLearning = local.ignoredFromLearning
    }

    func local(formatter: ISO8601DateFormatter) -> FocusSession {
        FocusSession(
            id: id,
            taskID: taskID,
            taskTitle: taskTitle,
            area: LifeArea(rawValue: area) ?? .errands,
            plannedMinutes: plannedMinutes,
            actualMinutes: actualMinutes,
            startedAt: formatter.date(from: startedAt) ?? .now,
            endedAt: formatter.date(from: endedAt) ?? .now,
            energyPreference: EnergyPreference(rawValue: energyPreference) ?? .normal,
            completedTask: completedTask,
            ignoredFromLearning: ignoredFromLearning
        )
    }
}

private struct CloudProfile: Codable {
    let id: UUID
    let userID: UUID
    let selectedAreas: String
    let gentleWeekdays: String
    let energyPeak: String
    let usualStartMinuteOfDay: Int
    let usualAvailableMinutes: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case selectedAreas = "selected_areas"
        case gentleWeekdays = "gentle_weekdays"
        case energyPeak = "energy_peak"
        case usualStartMinuteOfDay = "usual_start_minute_of_day"
        case usualAvailableMinutes = "usual_available_minutes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(local: LumaProfile, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        selectedAreas = local.selectedAreasRaw
        gentleWeekdays = local.gentleWeekdaysRaw
        energyPeak = local.energyPeakRaw
        usualStartMinuteOfDay = local.usualStartMinuteOfDay
        usualAvailableMinutes = local.usualAvailableMinutes
        createdAt = formatter.string(from: local.createdAt)
        updatedAt = formatter.string(from: local.updatedAt)
    }

    func local(formatter: ISO8601DateFormatter) -> LumaProfile {
        LumaProfile(
            id: id,
            selectedAreas: selectedAreas.split(separator: ",").compactMap { LifeArea(rawValue: String($0)) },
            gentleWeekdays: gentleWeekdays.split(separator: ",").compactMap { Int($0) },
            energyPeak: EnergyPeak(rawValue: energyPeak) ?? .afternoon,
            usualStartMinuteOfDay: usualStartMinuteOfDay,
            usualAvailableMinutes: usualAvailableMinutes,
            createdAt: formatter.date(from: createdAt) ?? .now,
            updatedAt: formatter.date(from: updatedAt) ?? .now
        )
    }
}

private struct CloudChatMessage: Codable {
    let id: UUID
    let userID: UUID
    let role: String
    let text: String
    let evidence: String
    let createdAt: String
    let actionID: UUID?
    let actionKind: String?
    let actionLabel: String?
    let actionTaskID: UUID?
    let actionEnergy: String?
    let actionAvailableMinutes: Int?
    let actionDurationMinutes: Int?
    let actionDate: String?
    let actionNumber: Double?
    let appliedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, role, text, evidence
        case userID = "user_id"
        case createdAt = "created_at"
        case actionID = "action_id"
        case actionKind = "action_kind"
        case actionLabel = "action_label"
        case actionTaskID = "action_task_id"
        case actionEnergy = "action_energy"
        case actionAvailableMinutes = "action_available_minutes"
        case actionDurationMinutes = "action_duration_minutes"
        case actionDate = "action_date"
        case actionNumber = "action_number"
        case appliedAt = "applied_at"
    }

    init(local: LumaChatRecord, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        role = local.roleRaw
        text = local.text
        evidence = local.evidenceRaw
        createdAt = formatter.string(from: local.createdAt)
        actionID = local.actionID
        actionKind = local.actionKindRaw
        actionLabel = local.actionLabel
        actionTaskID = local.actionTaskID
        actionEnergy = local.actionEnergyRaw
        actionAvailableMinutes = local.actionAvailableMinutes
        actionDurationMinutes = local.actionDurationMinutes
        actionDate = local.actionDate.map(formatter.string(from:))
        actionNumber = local.actionNumber
        appliedAt = local.appliedAt.map(formatter.string(from:))
    }

    func local(formatter: ISO8601DateFormatter) -> LumaChatRecord {
        LumaChatRecord(
            id: id,
            role: LumaChatRole(rawValue: role) ?? .assistant,
            text: text,
            evidence: evidence.split(separator: "\n").map(String.init),
            suggestedAction: actionKind.flatMap(LumaChatActionKind.init(rawValue:)).flatMap { kind in
                guard let actionLabel else { return nil }
                return LumaChatSuggestedAction(
                    id: actionID ?? UUID(),
                    kind: kind,
                    label: actionLabel,
                    taskID: actionTaskID,
                    energyPreference: actionEnergy.flatMap(EnergyPreference.init(rawValue:)),
                    availableMinutes: actionAvailableMinutes,
                    durationMinutes: actionDurationMinutes,
                    dateValue: actionDate.flatMap(formatter.date(from:)),
                    numericValue: actionNumber
                )
            },
            createdAt: formatter.date(from: createdAt) ?? .now,
            appliedAt: appliedAt.flatMap(formatter.date(from:))
        )
    }
}

private struct CloudReplanRecord: Codable {
    let id: UUID
    let userID: UUID
    let createdAt: String
    let source: String
    let reason: String
    let beforeEnergy: String
    let afterEnergy: String
    let beforeAvailableMinutes: Int
    let afterAvailableMinutes: Int
    let beforeTaskIDs: String
    let afterTaskIDs: String
    let beforeAgenda: String
    let afterAgenda: String
    let changeSummary: String

    enum CodingKeys: String, CodingKey {
        case id, source, reason
        case userID = "user_id"
        case createdAt = "created_at"
        case beforeEnergy = "before_energy"
        case afterEnergy = "after_energy"
        case beforeAvailableMinutes = "before_available_minutes"
        case afterAvailableMinutes = "after_available_minutes"
        case beforeTaskIDs = "before_task_ids"
        case afterTaskIDs = "after_task_ids"
        case beforeAgenda = "before_agenda"
        case afterAgenda = "after_agenda"
        case changeSummary = "change_summary"
    }

    init(local: LumaReplanRecord, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        createdAt = formatter.string(from: local.createdAt)
        source = local.sourceRaw
        reason = local.reason
        beforeEnergy = local.beforeEnergyRaw
        afterEnergy = local.afterEnergyRaw
        beforeAvailableMinutes = local.beforeAvailableMinutes
        afterAvailableMinutes = local.afterAvailableMinutes
        beforeTaskIDs = local.beforeTaskIDsRaw
        afterTaskIDs = local.afterTaskIDsRaw
        beforeAgenda = local.beforeAgendaData.base64EncodedString()
        afterAgenda = local.afterAgendaData.base64EncodedString()
        changeSummary = local.changeSummaryRaw
    }

    func local(formatter: ISO8601DateFormatter) -> LumaReplanRecord {
        LumaReplanRecord(
            id: id,
            createdAt: formatter.date(from: createdAt) ?? .now,
            sourceRaw: source,
            reason: reason,
            beforeEnergyRaw: beforeEnergy,
            afterEnergyRaw: afterEnergy,
            beforeAvailableMinutes: beforeAvailableMinutes,
            afterAvailableMinutes: afterAvailableMinutes,
            beforeTaskIDsRaw: beforeTaskIDs,
            afterTaskIDsRaw: afterTaskIDs,
            beforeAgendaData: Data(base64Encoded: beforeAgenda) ?? Data(),
            afterAgendaData: Data(base64Encoded: afterAgenda) ?? Data(),
            changeSummaryRaw: changeSummary
        )
    }
}
