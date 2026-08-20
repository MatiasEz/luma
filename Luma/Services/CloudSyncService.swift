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

    func sync(
        tasks: [LumaTask],
        sessions: [FocusSession],
        profiles: [LumaProfile],
        messages: [LumaChatRecord],
        replans: [LumaReplanRecord],
        subjects: [AcademicSubject],
        subjectGradeItems: [SubjectGradeItem],
        context: ModelContext
    ) async {
        guard let client else {
            state = .unconfigured
            return
        }
        guard !state.isBusy else { return }

        do {
            state = .connecting
            let userID = try await authenticatedUserID(using: client)
            self.userID = userID
            state = .syncing

            try await flushPendingTaskDeletions(userID: userID, client: client)

            try await pullRemoteData(
                userID: userID,
                client: client,
                tasks: tasks,
                sessions: sessions,
                profiles: profiles,
                messages: messages,
                replans: replans,
                subjects: subjects,
                subjectGradeItems: subjectGradeItems,
                context: context
            )
            try await pushLocalData(
                userID: userID,
                client: client,
                tasks: tasks,
                sessions: sessions,
                profiles: profiles,
                messages: messages,
                replans: replans,
                subjects: subjects,
                subjectGradeItems: subjectGradeItems
            )
            try context.save()
            lastSyncedAt = .now
            state = .synced
        } catch let error as URLError where error.code == .notConnectedToInternet {
            state = .offline
        } catch {
            state = .failed(error.localizedDescription)
        }
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
        subjectGradeItems: [SubjectGradeItem]
    ) async throws {
        if !tasks.isEmpty {
            try await client.from("tasks").upsert(tasks.map { CloudTask(local: $0, userID: userID, formatter: isoFormatter) }).execute()
        }
        if !sessions.isEmpty {
            try await client.from("focus_sessions").upsert(sessions.map { CloudFocusSession(local: $0, userID: userID, formatter: isoFormatter) }).execute()
        }
        if !profiles.isEmpty {
            try await client.from("profiles").upsert(profiles.map { CloudProfile(local: $0, userID: userID, formatter: isoFormatter) }).execute()
        }
        if !messages.isEmpty {
            try await client.from("chat_messages").upsert(messages.map { CloudChatMessage(local: $0, userID: userID, formatter: isoFormatter) }).execute()
        }
        if !replans.isEmpty {
            try await client.from("replan_records").upsert(replans.map { CloudReplanRecord(local: $0, userID: userID, formatter: isoFormatter) }).execute()
        }
        if !subjects.isEmpty {
            try await client.from("academic_subjects").upsert(subjects.map { CloudAcademicSubject(local: $0, userID: userID, formatter: isoFormatter) }).execute()
        }
        if !subjectGradeItems.isEmpty {
            try await client.from("subject_grade_items").upsert(subjectGradeItems.map { CloudSubjectGradeItem(local: $0, userID: userID, formatter: isoFormatter) }).execute()
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
        context: ModelContext
    ) async throws {
        let remoteTasks: [CloudTask] = try await client.from("tasks")
            .select().eq("user_id", value: userID).execute().value
        let taskIDs = Set(tasks.map(\.id))
        for record in remoteTasks where !taskIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteSessions: [CloudFocusSession] = try await client.from("focus_sessions")
            .select().eq("user_id", value: userID).execute().value
        let sessionIDs = Set(sessions.map(\.id))
        for record in remoteSessions where !sessionIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteProfiles: [CloudProfile] = try await client.from("profiles")
            .select().eq("user_id", value: userID).execute().value
        let profileIDs = Set(profiles.map(\.id))
        for record in remoteProfiles where !profileIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteMessages: [CloudChatMessage] = try await client.from("chat_messages")
            .select().eq("user_id", value: userID).execute().value
        let messageIDs = Set(messages.map(\.id))
        for record in remoteMessages where !messageIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteReplans: [CloudReplanRecord] = try await client.from("replan_records")
            .select().eq("user_id", value: userID).execute().value
        let replanIDs = Set(replans.map(\.id))
        for record in remoteReplans where !replanIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteSubjects: [CloudAcademicSubject] = try await client.from("academic_subjects")
            .select().eq("user_id", value: userID).execute().value
        let subjectIDs = Set(subjects.map(\.id))
        for record in remoteSubjects where !subjectIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }

        let remoteGradeItems: [CloudSubjectGradeItem] = try await client.from("subject_grade_items")
            .select().eq("user_id", value: userID).execute().value
        let gradeItemIDs = Set(subjectGradeItems.map(\.id))
        for record in remoteGradeItems where !gradeItemIDs.contains(record.id) {
            context.insert(record.local(formatter: isoFormatter))
        }
    }
}

private struct CloudAcademicSubject: Codable {
    let id: UUID
    let userID: UUID
    let name: String
    let targetGrade: Double?
    let createdAt: String
    let updatedAt: String
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case userID = "user_id"
        case targetGrade = "target_grade"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isArchived = "is_archived"
    }

    init(local: AcademicSubject, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        name = local.name
        targetGrade = local.targetGrade
        createdAt = formatter.string(from: local.createdAt)
        updatedAt = formatter.string(from: local.updatedAt)
        isArchived = local.isArchived
    }

    func local(formatter: ISO8601DateFormatter) -> AcademicSubject {
        AcademicSubject(
            id: id,
            name: name,
            targetGrade: targetGrade,
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

private struct CloudTask: Codable {
    let id: UUID
    let userID: UUID
    let title: String
    let area: String
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

    enum CodingKeys: String, CodingKey {
        case id, title, area, deadline, energy, impact, status, notes
        case userID = "user_id"
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
    }

    init(local: LumaTask, userID: UUID, formatter: ISO8601DateFormatter) {
        id = local.id
        self.userID = userID
        title = local.title
        area = local.areaRaw
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
        updatedAt = formatter.string(from: .now)
    }

    func local(formatter: ISO8601DateFormatter) -> LumaTask {
        LumaTask(
            id: id,
            title: title,
            area: LifeArea(rawValue: area) ?? .errands,
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
            completedAt: completedAt.flatMap(formatter.date(from:)),
            postponementCount: postponementCount,
            unlocksAnotherTask: unlocksAnotherTask,
            unlocksTaskID: unlocksTaskID,
            notes: notes,
            focusedMinutes: focusedMinutes,
            focusSessionCount: focusSessionCount,
            lastFocusedAt: lastFocusedAt.flatMap(formatter.date(from:))
        )
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
                    durationMinutes: actionDurationMinutes
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
