import Foundation
import Observation

@MainActor
@Observable
final class AppShellViewModel {
    func cloudFingerprint(
        tasks: [LumaTask],
        sessions: [FocusSession],
        profiles: [LumaProfile],
        messages: [LumaChatRecord],
        replans: [LumaReplanRecord],
        subjects: [AcademicSubject],
        gradeItems: [SubjectGradeItem]
    ) -> String {
        let taskPart = tasks.map {
            [
                $0.id.uuidString,
                $0.title,
                $0.statusRaw,
                "\($0.updatedAt.timeIntervalSinceReferenceDate)",
                "\($0.focusedMinutes)",
                "\($0.postponementCount)",
                $0.academicSubjectID?.uuidString ?? "sin-materia",
                $0.subjectGradeItemID?.uuidString ?? "sin-categoria",
                $0.grade.map { String($0) } ?? "sin-nota",
                $0.unlocksTaskID?.uuidString ?? "sin-dependencia",
            ].joined(separator: ":")
        }.joined(separator: "|")
        let sessionPart = sessions.map { "\($0.id):\($0.actualMinutes):\($0.completedTask)" }.joined(separator: "|")
        let profilePart = profiles.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
        let chatPart = messages.map { "\($0.id):\($0.appliedAt?.timeIntervalSinceReferenceDate ?? 0)" }.joined(separator: "|")
        let replanPart = replans.map(\.id.uuidString).joined(separator: "|")
        let subjectPart = subjects.map { subject in
            let target = subject.targetGrade.map { String($0) } ?? "sin-objetivo"
            return "\(subject.id):\(subject.name):\(target):\(subject.updatedAt.timeIntervalSinceReferenceDate):\(subject.isArchived)"
        }.joined(separator: "|")
        let gradeItemPart = gradeItems.map {
            "\($0.id):\($0.title):\($0.weightPercent):\($0.updatedAt.timeIntervalSinceReferenceDate):\($0.isArchived)"
        }.joined(separator: "|")
        return "\(taskPart)#\(sessionPart)#\(profilePart)#\(chatPart)#\(replanPart)#\(subjectPart)#\(gradeItemPart)"
    }

    func attentionCount(
        tasks: [LumaTask],
        subjects: [AcademicSubject],
        gradeItems: [SubjectGradeItem],
        cloudState: CloudSyncState,
        calendarError: String?,
        now: Date = .now
    ) -> Int {
        let taskIssues = tasks.filter { task in
            task.academicEvaluationStatus == .awaitingGrade
                || (!task.isCompleted && (task.deadline.map { $0 < now } ?? false))
                || (!task.isCompleted && TaskDependencyResolver.isBlocked(task, in: tasks))
                || (!task.isCompleted && task.deadline == nil
                    && now.timeIntervalSince(task.createdAt) >= 3 * 86_400)
        }.count
        let subjectIssues = subjects.filter { subject in
            guard !subject.isArchived else { return false }
            let total = gradeItems
                .filter { !$0.isArchived && $0.subjectID == subject.id }
                .reduce(0) { $0 + $1.weightPercent }
            return abs(total - 100) > 0.001
        }.count
        let cloudIssue: Int
        if case .failed = cloudState { cloudIssue = 1 } else { cloudIssue = 0 }
        return taskIssues + subjectIssues + cloudIssue + (calendarError == nil ? 0 : 1)
    }
}

@MainActor
@Observable
final class DashboardViewModel {
    var agendaSettingsPresented = false
    var calendarFeedback = ""

    func recommendations(
        tasks: [LumaTask],
        planner: TaskPlanner,
        appState: AppState
    ) -> [PlanRecommendation] {
        appState.dailyRecommendations(from: tasks, planner: planner)
    }
}

@MainActor
@Observable
final class InboxViewModel {
    var selectedArea: LifeArea?
    var selectedSmartFilter: SmartTaskFilter = .all
    var showCompleted = false
    var editingTask: LumaTask?
    var selectedTask: LumaTask?

    func filteredTasks(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { task in
            (selectedArea == nil || task.area == selectedArea)
                && selectedSmartFilter.matches(task, in: tasks)
                && (showCompleted || !task.isCompleted || task.academicEvaluationStatus == .awaitingGrade)
        }
    }

    func awaitingGradeTasks(from tasks: [LumaTask]) -> [LumaTask] {
        filteredTasks(from: tasks).filter { $0.academicEvaluationStatus == .awaitingGrade }
    }

    func regularTasks(from tasks: [LumaTask]) -> [LumaTask] {
        filteredTasks(from: tasks).filter { $0.academicEvaluationStatus != .awaitingGrade }
    }

    func inboxCountText(tasks: [LumaTask]) -> String {
        let open = tasks.filter { !$0.isCompleted }.count
        let awaiting = tasks.filter { $0.academicEvaluationStatus == .awaitingGrade }.count
        return awaiting == 0
            ? "\(open) pendientes"
            : "\(open) pendientes · \(awaiting) esperando nota"
    }

    func subjectName(for task: LumaTask, subjects: [AcademicSubject]) -> String? {
        guard let id = task.academicSubjectID else { return nil }
        return subjects.first { $0.id == id }?.name
    }

    func categoryName(for task: LumaTask, gradeItems: [SubjectGradeItem]) -> String? {
        guard let id = task.subjectGradeItemID else { return nil }
        return gradeItems.first { $0.id == id }?.title
    }

    func blockerNames(for task: LumaTask, tasks: [LumaTask]) -> [String] {
        TaskDependencyResolver.blockers(for: task.id, in: tasks).map(\.title)
    }

    func unlockedTaskName(for task: LumaTask, tasks: [LumaTask]) -> String? {
        guard let targetID = task.unlocksTaskID else { return nil }
        return tasks.first { $0.id == targetID }?.title
    }
}

@MainActor
@Observable
final class AttentionViewModel {
    var editingTask: LumaTask?

    func awaitingGrade(tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { $0.academicEvaluationStatus == .awaitingGrade }
    }

    func overdue(tasks: [LumaTask], now: Date = .now) -> [LumaTask] {
        tasks.filter { !$0.isCompleted && ($0.deadline.map { $0 < now } ?? false) }
    }

    func blocked(tasks: [LumaTask], now: Date = .now) -> [LumaTask] {
        let overdueIDs = Set(overdue(tasks: tasks, now: now).map(\.id))
        return tasks.filter {
            !$0.isCompleted && !overdueIDs.contains($0.id)
                && TaskDependencyResolver.isBlocked($0, in: tasks)
        }
    }

    func staleWithoutDate(tasks: [LumaTask], now: Date = .now) -> [LumaTask] {
        let blockedIDs = Set(blocked(tasks: tasks, now: now).map(\.id))
        return tasks.filter {
            !$0.isCompleted && $0.deadline == nil && !blockedIDs.contains($0.id)
                && now.timeIntervalSince($0.createdAt) >= 3 * 86_400
        }
    }

    func incompleteSubjects(
        subjects: [AcademicSubject],
        gradeItems: [SubjectGradeItem]
    ) -> [(subject: AcademicSubject, configured: Double)] {
        subjects.compactMap { subject in
            guard !subject.isArchived else { return nil }
            let total = gradeItems
                .filter { !$0.isArchived && $0.subjectID == subject.id }
                .reduce(0) { $0 + $1.weightPercent }
            return abs(total - 100) > 0.001 ? (subject, total) : nil
        }
    }
}

@MainActor
@Observable
final class WeekViewModel {
    func days(now: Date = .now, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: now)
        return (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func tasks(on day: Date, from tasks: [LumaTask], calendar: Calendar = .current) -> [LumaTask] {
        tasks.filter { task in
            guard !task.isCompleted, let deadline = task.deadline else { return false }
            return calendar.isDate(deadline, inSameDayAs: day)
        }
    }

    func tasksWithoutDate(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { !$0.isCompleted && $0.deadline == nil }
    }
}

@MainActor
@Observable
final class BalanceViewModel {
    func activeTasks(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { !$0.isCompleted }
    }

    func minutes(for area: LifeArea, tasks: [LumaTask]) -> Int {
        activeTasks(from: tasks).filter { $0.area == area }.reduce(0) { $0 + $1.estimatedMinutes }
    }

    func maximumMinutes(tasks: [LumaTask]) -> Double {
        max(1, LifeArea.allCases.map { Double(minutes(for: $0, tasks: tasks)) }.max() ?? 1)
    }

    func formattedMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    func areaMessage(_ area: LifeArea, minutes: Int, maximumMinutes: Double) -> String {
        if minutes == 0 {
            return area == .rest ? "Hay espacio para descanso real." : "Sin carga visible esta semana."
        }
        if Double(minutes) / maximumMinutes > 0.8 {
            return "Esta área está llevando bastante peso."
        }
        return "Carga manejable por ahora."
    }
}

@MainActor
@Observable
final class AgendaSettingsViewModel {
    var availabilityWindows: [AvailabilityWindow] = []
    var energyPreference = EnergyPreference.normal

    var totalAvailableMinutes: Int {
        availabilityWindows.reduce(0) { $0 + $1.durationMinutes }
    }

    func load(from agenda: DailyAgendaSnapshot?, fallbackEnergy: EnergyPreference) {
        availabilityWindows = agenda?.availabilityWindows ?? []
        energyPreference = fallbackEnergy
    }

    func setQuickAvailability(_ minutes: Int, defaultStart: Int) {
        guard minutes > 0 else {
            availabilityWindows = []
            return
        }
        let end = min(23 * 60 + 45, defaultStart + minutes)
        let start = max(0, min(defaultStart, end - 15))
        availabilityWindows = [AvailabilityWindow(
            startMinuteOfDay: start,
            endMinuteOfDay: end
        )]
    }
}
