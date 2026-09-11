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
        gradeItems: [SubjectGradeItem],
        classMeetings: [SubjectClassMeeting] = [],
        routines: [AcademicRoutine] = [],
        exams: [AcademicExam] = [],
        dailyContexts: [DailyPlanningContext] = []
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
        let sessionPart = sessions.map { "\($0.id):\($0.actualMinutes):\($0.completedTask):\($0.ignoredFromLearning):\($0.updatedAt?.timeIntervalSince1970 ?? 0)" }.joined(separator: "|")
        let profilePart = profiles.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
        let chatPart = messages.map { "\($0.id):\($0.appliedAt?.timeIntervalSinceReferenceDate ?? 0)" }.joined(separator: "|")
        let replanPart = replans.map(\.id.uuidString).joined(separator: "|")
        let subjectPart = subjects.map { subject in
            let target = subject.targetGrade.map { String($0) } ?? "sin-objetivo"
            return "\(subject.id):\(subject.name):\(target):\(subject.colorHex):\(subject.syllabusRaw):\(subject.updatedAt.timeIntervalSinceReferenceDate):\(subject.isArchived)"
        }.joined(separator: "|")
        let gradeItemPart = gradeItems.map {
            "\($0.id):\($0.title):\($0.weightPercent):\($0.updatedAt.timeIntervalSinceReferenceDate):\($0.isArchived)"
        }.joined(separator: "|")
        let academicPart = classMeetings.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + routines.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + exams.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
            + dailyContexts.map { "\($0.id):\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
        return "\(taskPart)#\(sessionPart)#\(profilePart)#\(chatPart)#\(replanPart)#\(subjectPart)#\(gradeItemPart)#\(academicPart)"
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
                || (!task.isCompleted && ((task.dueDate ?? task.deadline).map { $0 < now } ?? false))
                || (!task.isCompleted && TaskDependencyResolver.isBlocked(task, in: tasks))
                || (!task.isCompleted && task.dueDate == nil && task.deadline == nil
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
    var visibleRecommendations: [PlanRecommendation] = []
    var optionalRecommendation: PlanRecommendation?
    var restRecommendation: PlanRecommendation?
    var needsCapacityDecision = false
    var scheduledOutsidePlan: [LumaTask] = []
    var overdueTasksNeedingReview: [LumaTask] = []
    var workload: WorkloadLevel = .low
    var rhythmProfile: UserRhythmProfile = .empty
    var hasPreparedPresentation = false

    func refreshPresentation(
        tasks: [LumaTask],
        planner: TaskPlanner,
        appState: AppState,
        now: Date = .now,
        busyBlocks: [BusyTimeBlock]? = nil
    ) {
        appState.refreshSharedPlan(tasks: tasks, planner: planner, now: now, busyBlocks: busyBlocks)
        visibleRecommendations = appState.dailyRecommendations(from: tasks, planner: planner, now: now)
        let plannedIDs = Set(visibleRecommendations.map(\.task.id))
        // Spare time is allocated when a plan is created. A completed block must
        // not be treated as newly available time for another automatic suggestion.
        optionalRecommendation = appState.dailyPlan == nil
            ? planner.optionalRecommendation(
                from: tasks,
                excluding: plannedIDs,
                now: now,
                preference: appState.energyPreference
            )
            : nil
        let savedRestMinutes = appState.dailyPlan.flatMap { plan in
            Calendar.current.isDate(plan.day, inSameDayAs: now) ? plan.restMinutes : nil
        }
        restRecommendation = planner.restRecommendation(
            from: tasks,
            now: now,
            preference: appState.energyPreference,
            budgetOverride: appState.remainingAvailableMinutes(fallback: planner.availableTimeBudget, now: now),
            savedMinutes: savedRestMinutes
        )
        needsCapacityDecision = planner.needsCapacityDecision(
            from: tasks,
            recommendations: visibleRecommendations.map { item in
                let minutes = appState.workBlocks(on: now, taskID: item.id).filter { $0.status != .completed }.reduce(0) { $0 + $1.minutes }
                return PlanRecommendation(task: item.task, score: item.score, reason: item.reason, suggestedMinutes: max(minutes, item.suggestedMinutes))
            },
            now: now,
            preference: appState.energyPreference
        )
        scheduledOutsidePlan = planner.scheduledTasksOutsidePlan(
            from: tasks,
            excluding: plannedIDs,
            now: now
        )
        overdueTasksNeedingReview = planner.overdueTasksNeedingReview(from: tasks, now: now)
        workload = appState.sharedPlan.capacityIssues.isEmpty ? planner.workload(from: tasks, now: now) : .high
        hasPreparedPresentation = true
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

    var hasCustomFilters: Bool {
        selectedSmartFilter != .all || selectedArea != nil || showCompleted
    }

    func select(_ filter: SmartTaskFilter) {
        selectedSmartFilter = filter
    }

    func resetFilters() {
        selectedSmartFilter = .all
        selectedArea = nil
        showCompleted = false
    }

    func filteredTasks(
        from tasks: [LumaTask],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [LumaTask] {
        let matches = tasks.filter { task in
            if task.planningDetails.isRetired == true { return false }
            let matchesArea = selectedArea == nil || task.area == selectedArea
            let matchesFilter = selectedSmartFilter.matches(
                task,
                in: tasks,
                now: now,
                calendar: calendar
            )
            let matchesCompletion: Bool
            if selectedSmartFilter == .completed {
                matchesCompletion = task.isCompleted
            } else {
                matchesCompletion = showCompleted || !task.isCompleted
            }
            return matchesArea && matchesFilter && matchesCompletion
        }

        return matches.sorted { lhs, rhs in
            switch selectedSmartFilter {
            case .week:
                let lhsDate = selectedSmartFilter.relevantDate(for: lhs, now: now, calendar: calendar)
                let rhsDate = selectedSmartFilter.relevantDate(for: rhs, now: now, calendar: calendar)
                if lhsDate != rhsDate {
                    return (lhsDate ?? .distantFuture) < (rhsDate ?? .distantFuture)
                }
            case .evaluations:
                let lhsDate = lhs.dueDate ?? lhs.deadline
                let rhsDate = rhs.dueDate ?? rhs.deadline
                if lhsDate != rhsDate {
                    return (lhsDate ?? .distantFuture) < (rhsDate ?? .distantFuture)
                }
            case .completed:
                let lhsDate = lhs.completedAt ?? lhs.updatedAt
                let rhsDate = rhs.completedAt ?? rhs.updatedAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
            default:
                break
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func regularTasks(
        from tasks: [LumaTask],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [LumaTask] {
        filteredTasks(from: tasks, now: now, calendar: calendar)
    }

    func inboxCountText(tasks: [LumaTask]) -> String {
        let open = tasks.filter { !$0.isCompleted }.count
        guard hasCustomFilters else { return "\(open) pendientes" }

        let visible = filteredTasks(from: tasks)
        if selectedSmartFilter == .completed {
            return visible.count == 1 ? "1 hecha" : "\(visible.count) hechas"
        }
        if showCompleted {
            return visible.count == 1 ? "1 resultado" : "\(visible.count) resultados"
        }
        return "\(visible.count) de \(open) pendientes"
    }

    func subjectName(for task: LumaTask, subjects: [AcademicSubject]) -> String? {
        guard let id = task.academicSubjectID else { return nil }
        return subjects.first { $0.id == id }?.name
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
        tasks.filter { !$0.isCompleted && (($0.dueDate ?? $0.deadline).map { $0 < now } ?? false) }
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
            !$0.isCompleted && $0.dueDate == nil && $0.deadline == nil && !blockedIDs.contains($0.id)
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

enum CalendarSpan: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Semana"
        case .month: "Mes"
        }
    }
}

struct CalendarClassOccurrence: Identifiable {
    let meeting: SubjectClassMeeting
    let subject: AcademicSubject

    var id: UUID { meeting.id }
}

struct CalendarExamOccurrence: Identifiable {
    let exam: AcademicExam
    let subject: AcademicSubject

    var id: UUID { exam.id }
}

enum CalendarDayItem: Identifiable {
    case exam(CalendarExamOccurrence)
    case task(LumaTask)
    case classMeeting(CalendarClassOccurrence)

    var id: String {
        switch self {
        case let .exam(occurrence):
            "exam-\(occurrence.id.uuidString)"
        case let .task(task):
            "task-\(task.id.uuidString)"
        case let .classMeeting(occurrence):
            "class-\(occurrence.id.uuidString)"
        }
    }
}

@MainActor
@Observable
final class WeekViewModel {
    var span = CalendarSpan.week
    var referenceDate = Date.now
    var scheduleFeedback = ""
    var selectedTask: LumaTask?
    var selectedExam: AcademicExam?
    var editingTask: LumaTask?
    var pendingTaskID: UUID?
    var pendingDay: Date?
    var pendingTime = Date.now
    var isTimePickerPresented = false

    func visibleDays(calendar: Calendar = .current) -> [Date] {
        switch span {
        case .week:
            let start = startOfWeek(containing: referenceDate, calendar: calendar)
            return days(from: start, count: 7, calendar: calendar)
        case .month:
            guard let month = calendar.dateInterval(of: .month, for: referenceDate) else { return [] }
            let firstVisibleDay = startOfWeek(containing: month.start, calendar: calendar)
            let lastMonthDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.start
            let lastVisibleWeek = startOfWeek(containing: lastMonthDay, calendar: calendar)
            let dayDistance = calendar.dateComponents(
                [.day],
                from: firstVisibleDay,
                to: lastVisibleWeek
            ).day ?? 0
            return days(from: firstVisibleDay, count: dayDistance + 7, calendar: calendar)
        }
    }

    func movePeriod(_ offset: Int, calendar: Calendar = .current) {
        let component: Calendar.Component = span == .week ? .weekOfYear : .month
        referenceDate = calendar.date(byAdding: component, value: offset, to: referenceDate) ?? referenceDate
        scheduleFeedback = ""
    }

    func showToday() {
        referenceDate = .now
        scheduleFeedback = ""
    }

    func periodTitle(calendar: Calendar = .current) -> String {
        switch span {
        case .month:
            return referenceDate.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "es_AR")))
        case .week:
            let visible = visibleDays(calendar: calendar)
            guard let first = visible.first, let last = visible.last else { return "Semana" }
            if calendar.component(.month, from: first) == calendar.component(.month, from: last) {
                return "\(first.formatted(.dateTime.day().locale(Locale(identifier: "es_AR"))))–\(last.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "es_AR"))))"
            }
            return "\(first.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_AR")))) – \(last.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "es_AR"))))"
        }
    }

    func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let start = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[start...]) + Array(symbols[..<start])
    }

    func isInDisplayedMonth(_ day: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.month, from: day) == calendar.component(.month, from: referenceDate)
            && calendar.component(.year, from: day) == calendar.component(.year, from: referenceDate)
    }

    func tasks(on day: Date, from tasks: [LumaTask], calendar: Calendar = .current) -> [LumaTask] {
        tasks.filter { task in
            let delivery = task.academicSourceType == .examStudy ? nil : task.dueDate
            return [task.deadline, delivery].compactMap { $0 }.contains { calendar.isDate($0, inSameDayAs: day) }
        }
        .sorted {
            if let lhs = $0.deadline, let rhs = $1.deadline, lhs != rhs { return lhs < rhs }
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.area != $1.area { return $0.area.title < $1.area.title }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func classMeetings(
        on day: Date,
        from meetings: [SubjectClassMeeting],
        subjects: [AcademicSubject],
        calendar: Calendar = .current
    ) -> [CalendarClassOccurrence] {
        let weekday = calendar.component(.weekday, from: day)
        let subjectsByID = Dictionary(
            uniqueKeysWithValues: subjects
                .filter { !$0.isArchived }
                .map { ($0.id, $0) }
        )

        return meetings
            .filter { $0.weekday == weekday }
            .compactMap { meeting in
                guard let subject = subjectsByID[meeting.subjectID] else { return nil }
                return CalendarClassOccurrence(meeting: meeting, subject: subject)
            }
            .sorted {
                if $0.meeting.startMinuteOfDay != $1.meeting.startMinuteOfDay {
                    return $0.meeting.startMinuteOfDay < $1.meeting.startMinuteOfDay
                }
                return $0.subject.name.localizedCaseInsensitiveCompare($1.subject.name) == .orderedAscending
            }
    }

    func calendarItems(
        on day: Date,
        tasks: [LumaTask],
        meetings: [SubjectClassMeeting],
        exams: [AcademicExam] = [],
        subjects: [AcademicSubject],
        includeClassMeetings: Bool = true,
        calendar: Calendar = .current
    ) -> [CalendarDayItem] {
        let taskItems = self.tasks(on: day, from: tasks, calendar: calendar).map(CalendarDayItem.task)
        let classItems = includeClassMeetings
            ? classMeetings(
                on: day,
                from: meetings,
                subjects: subjects,
                calendar: calendar
            ).map(CalendarDayItem.classMeeting)
            : []
        let examItems = examOccurrences(
            on: day,
            from: exams,
            subjects: subjects,
            calendar: calendar
        ).map(CalendarDayItem.exam)

        return (examItems + taskItems + classItems).sorted { lhs, rhs in
            let lhsMinute = minuteOfDay(for: lhs, calendar: calendar)
            let rhsMinute = minuteOfDay(for: rhs, calendar: calendar)
            if lhsMinute != rhsMinute { return lhsMinute < rhsMinute }

            switch (lhs, rhs) {
            case (.exam, _): return true
            case (_, .exam): return false
            case (.classMeeting, .task): return true
            case (.task, .classMeeting): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    func examOccurrences(
        on day: Date,
        from exams: [AcademicExam],
        subjects: [AcademicSubject],
        calendar: Calendar = .current
    ) -> [CalendarExamOccurrence] {
        let subjectsByID = Dictionary(
            uniqueKeysWithValues: subjects
                .filter { !$0.isArchived }
                .map { ($0.id, $0) }
        )

        return exams
            .filter { !$0.isArchived && calendar.isDate($0.date, inSameDayAs: day) }
            .compactMap { exam in
                guard let subject = subjectsByID[exam.subjectID] else { return nil }
                return CalendarExamOccurrence(exam: exam, subject: subject)
            }
            .sorted {
                $0.exam.title.localizedCaseInsensitiveCompare($1.exam.title) == .orderedAscending
            }
    }

    func tasksWithoutDate(from tasks: [LumaTask]) -> [LumaTask] {
        tasks
            .filter { !$0.isCompleted && $0.deadline == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func subjectName(for task: LumaTask, subjects: [AcademicSubject]) -> String? {
        guard let id = task.academicSubjectID else { return nil }
        return subjects.first { $0.id == id }?.name
    }

    func blockerNames(for task: LumaTask, tasks: [LumaTask]) -> [String] {
        TaskDependencyResolver.blockers(for: task.id, in: tasks).map(\.title)
    }

    func unlockedTaskName(for task: LumaTask, tasks: [LumaTask]) -> String? {
        guard let targetID = task.unlocksTaskID else { return nil }
        return tasks.first { $0.id == targetID }?.title
    }

    func beginScheduling(
        taskID: UUID,
        on day: Date,
        calendar: Calendar = .current,
        now: Date = .now
    ) {
        pendingTaskID = taskID
        pendingDay = day

        let defaultHour: Int
        if calendar.isDate(day, inSameDayAs: now) {
            defaultHour = min(calendar.component(.hour, from: now) + 1, 23)
        } else {
            defaultHour = 17
        }
        pendingTime = calendar.date(
            bySettingHour: defaultHour,
            minute: 0,
            second: 0,
            of: day
        ) ?? day
        isTimePickerPresented = true
    }

    func setPendingHour(_ hour: Int, calendar: Calendar = .current) {
        guard let day = pendingDay else { return }
        pendingTime = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: day
        ) ?? pendingTime
    }

    func cancelScheduling() {
        pendingTaskID = nil
        pendingDay = nil
        isTimePickerPresented = false
    }

    func pendingTask(from tasks: [LumaTask]) -> LumaTask? {
        guard let pendingTaskID else { return nil }
        return tasks.first { $0.id == pendingTaskID && !$0.isCompleted }
    }

    func assignPendingTask(
        from tasks: [LumaTask],
        calendar: Calendar = .current
    ) -> LumaTask? {
        guard let task = pendingTask(from: tasks), let day = pendingDay else { return nil }
        let time = calendar.dateComponents([.hour, .minute], from: pendingTime)
        guard let scheduledDate = calendar.date(
            bySettingHour: time.hour ?? 17,
            minute: time.minute ?? 0,
            second: 0,
            of: day
        ) else { return nil }

        task.deadline = scheduledDate
        task.touch()
        scheduleFeedback = "\(task.title) · \(scheduledDate.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))"
        cancelScheduling()
        return task
    }

    private func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    private func days(from start: Date, count: Int, calendar: Calendar) -> [Date] {
        (0 ..< count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func minuteOfDay(for item: CalendarDayItem, calendar: Calendar) -> Int {
        switch item {
        case .exam:
            return -1
        case let .task(task):
            guard let deadline = task.deadline else { return Int.max }
            return calendar.component(.hour, from: deadline) * 60
                + calendar.component(.minute, from: deadline)
        case let .classMeeting(occurrence):
            return occurrence.meeting.startMinuteOfDay
        }
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
