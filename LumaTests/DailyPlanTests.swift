@testable import Luma
import XCTest

@MainActor
final class DailyPlanTests: XCTestCase {
    func testPlanKeepsItsThreePrioritiesDuringTheSameDay() throws {
        let setup = makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }

        let tasks = makeTasks(now: setup.now)
        let state = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        let planner = TaskPlanner(calendar: setup.calendar)

        let update = state.prepareDailyPlan(from: tasks, planner: planner, now: setup.now)
        let originalIDs = try XCTUnwrap(state.dailyPlan?.taskIDs)
        XCTAssertTrue(update.created)
        XCTAssertEqual(originalIDs.count, 3)

        let urgentNewTask = LumaTask(
            title: "Urgencia nueva",
            area: .errands,
            deadline: setup.now,
            estimatedMinutes: 10,
            energy: .low,
            impact: .urgency
        )
        let expandedTasks = tasks + [urgentNewTask]

        _ = state.prepareDailyPlan(from: expandedTasks, planner: planner, now: setup.now)
        let visibleIDs = state.dailyRecommendations(
            from: expandedTasks,
            planner: planner,
            now: setup.now
        ).map(\.task.id)

        XCTAssertEqual(visibleIDs, originalIDs)
        XCTAssertFalse(visibleIDs.contains(urgentNewTask.id))
    }

    func testNextDayPostponesUnfinishedPrioritiesOnce() throws {
        let setup = makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }

        let tasks = makeTasks(now: setup.now)
        let state = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        let planner = TaskPlanner(calendar: setup.calendar)

        _ = state.prepareDailyPlan(from: tasks, planner: planner, now: setup.now)
        let plannedIDs = try Set(XCTUnwrap(state.dailyPlan?.taskIDs))
        let tomorrow = try XCTUnwrap(setup.calendar.date(byAdding: .day, value: 1, to: setup.now))

        let firstUpdate = state.prepareDailyPlan(from: tasks, planner: planner, now: tomorrow)
        let secondUpdate = state.prepareDailyPlan(from: tasks, planner: planner, now: tomorrow)

        XCTAssertTrue(firstUpdate.rolledOver)
        XCTAssertEqual(firstUpdate.postponedCount, plannedIDs.count)
        XCTAssertFalse(secondUpdate.rolledOver)
        for task in tasks {
            XCTAssertEqual(task.postponementCount, plannedIDs.contains(task.id) ? 1 : 0)
        }
    }

    func testPlanAndEnergyPersistAcrossAppStateInstances() throws {
        let setup = makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }

        let tasks = makeTasks(now: setup.now)
        let planner = TaskPlanner(calendar: setup.calendar)
        let firstState = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        firstState.replanDaily(
            from: tasks,
            planner: planner,
            preference: .tired,
            now: setup.now
        )

        let restored = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)

        XCTAssertEqual(restored.dailyPlan, firstState.dailyPlan)
        XCTAssertEqual(restored.energyPreference, .tired)
        XCTAssertEqual(try XCTUnwrap(restored.dailyPlan).energyPreference, .tired)
    }

    func testShortBlockSurvivesCompletionReopeningAndReplanUndo() throws {
        let setup = makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }

        let tasks = (0 ..< 3).map { index in
            LumaTask(
                title: "Avance \(index)",
                area: [LifeArea.university, .sideHustle, .home][index],
                dueDate: setup.now.addingTimeInterval(Double(index < 2 ? 1 : 7) * 86400),
                estimatedMinutes: 90,
                createdAt: setup.now.addingTimeInterval(Double(index))
            )
        } + [LumaTask(
            title: "Descanso",
            area: .hobbies,
            estimatedMinutes: 30,
            energy: .low,
            impact: .wellbeing,
            sourceTypeRaw: AcademicTaskSourceType.rest.rawValue,
            sourceOccurrenceDate: setup.now
        )]
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 120, restCounts: true)
        let state = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        _ = state.prepareDailyPlan(from: tasks, planner: planner, now: setup.now)
        let original = state.dailyRecommendations(from: tasks, planner: planner, now: setup.now)
        let shortBlock = try XCTUnwrap(original.last)

        XCTAssertEqual(original.map(\.suggestedMinutes), [45, 45, 15])
        XCTAssertEqual(state.dailyPlan?.suggestedMinutesByTaskID?[shortBlock.id], 15)

        let completedBlock = try XCTUnwrap(original.first)
        completedBlock.task.markCompleted()
        state.finishPlannedBlock(for: completedBlock.id)
        _ = state.prepareDailyPlan(from: tasks, planner: planner, now: setup.now)
        let remaining = state.dailyRecommendations(from: tasks, planner: planner, now: setup.now)

        XCTAssertEqual(remaining.map(\.task.id), original.dropFirst().map(\.task.id))
        XCTAssertEqual(remaining.map(\.suggestedMinutes), [45, 15])

        let restored = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        let reopenedPlan = restored.dailyRecommendations(from: tasks, planner: planner, now: setup.now)
        XCTAssertEqual(reopenedPlan.map(\.task.id), remaining.map(\.task.id))
        XCTAssertEqual(reopenedPlan.map(\.suggestedMinutes), [45, 15])

        let proposal = ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: "Hoy tengo menos tiempo",
            tasks: tasks,
            currentPlan: restored.dailyPlan,
            currentAgenda: nil,
            currentEnergy: .normal,
            proposedEnergy: .normal,
            currentAvailableMinutes: 120,
            proposedAvailableMinutes: 60,
            planner: planner,
            scheduler: DailyScheduler(calendar: setup.calendar),
            now: setup.now
        )
        restored.applyReplan(proposal)
        _ = restored.prepareDailyPlan(
            from: tasks,
            planner: planner,
            inputFingerprint: "contexto-reacomodado",
            now: setup.now
        )
        XCTAssertEqual(
            restored.dailyRecommendations(from: tasks, planner: planner, now: setup.now).map(\.suggestedMinutes),
            [45]
        )
        restored.restoreReplan(proposal)
        _ = restored.prepareDailyPlan(
            from: tasks,
            planner: planner,
            inputFingerprint: "contexto-restaurado",
            now: setup.now
        )
        XCTAssertEqual(
            restored.dailyRecommendations(from: tasks, planner: planner, now: setup.now).map(\.suggestedMinutes),
            [45, 15]
        )
    }

    func testFinishingAShortBlockKeepsCapacityWarningForUnfinishedDelivery() {
        let setup = makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }

        let task = LumaTask(
            title: "Entrega de mañana",
            area: .university,
            dueDate: setup.now.addingTimeInterval(86400),
            estimatedMinutes: 90,
            createdAt: setup.now
        )
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 120)
        let state = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        _ = state.prepareDailyPlan(from: [task], planner: planner, now: setup.now)

        task.recordFocusSession(minutes: 45, at: setup.now)
        state.finishPlannedBlock(for: task.id)
        let viewModel = DashboardViewModel()
        viewModel.refreshPresentation(tasks: [task], planner: planner, appState: state, now: setup.now)

        XCTAssertFalse(task.isCompleted)
        XCTAssertEqual(task.remainingEstimatedMinutes, 45)
        XCTAssertTrue(viewModel.visibleRecommendations.isEmpty)
        XCTAssertTrue(viewModel.needsCapacityDecision)
    }

    func testLegacySavedPlanWithoutBlockDurationsStillRestores() throws {
        let setup = makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }

        let tasks = makeTasks(now: setup.now)
        let originalIDs = tasks.prefix(3).map(\.id)
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "day": setup.now.timeIntervalSinceReferenceDate,
            "taskIDs": originalIDs.map(\.uuidString),
            "energyPreference": EnergyPreference.normal.rawValue,
        ])
        setup.defaults.set(legacyData, forKey: "lumaDailyPlanSnapshot")

        let restored = AppState(defaults: setup.defaults, calendar: setup.calendar, now: setup.now)
        let recommendations = restored.dailyRecommendations(
            from: tasks,
            planner: TaskPlanner(calendar: setup.calendar),
            now: setup.now
        )

        XCTAssertEqual(try XCTUnwrap(restored.dailyPlan).taskIDs, originalIDs)
        XCTAssertEqual(recommendations.map(\.task.id), originalIDs)
        XCTAssertTrue(recommendations.allSatisfy { $0.suggestedMinutes > 0 && $0.suggestedMinutes <= 45 })
    }

    private func makeSetup() -> (defaults: UserDefaults, suiteName: String, calendar: Calendar, now: Date) {
        let suiteName = "DailyPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 9))!
        return (defaults, suiteName, calendar, now)
    }

    private func makeTasks(now: Date) -> [LumaTask] {
        [
            LumaTask(
                title: "Entrega importante",
                area: .university,
                deadline: now.addingTimeInterval(86400),
                estimatedMinutes: 90,
                energy: .high,
                impact: .grade,
                academicWeight: 30
            ),
            LumaTask(
                title: "Enviar cotización",
                area: .sideHustle,
                deadline: now.addingTimeInterval(2 * 86400),
                estimatedMinutes: 25,
                energy: .medium,
                impact: .money
            ),
            LumaTask(
                title: "Ordenar papeles",
                area: .errands,
                deadline: now.addingTimeInterval(3 * 86400),
                estimatedMinutes: 20,
                energy: .low,
                impact: .urgency
            ),
            LumaTask(
                title: "Practicar guitarra",
                area: .hobbies,
                deadline: now.addingTimeInterval(5 * 86400),
                estimatedMinutes: 45,
                energy: .low,
                impact: .wellbeing
            ),
        ]
    }
}

@MainActor
final class InboxFilterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testWeekUsesBothScheduledAndDeliveryDatesAndSortsChronologically() {
        let now = date(day: 3, hour: 14)
        let deliveryEarlierThisWeek = LumaTask(
            title: "Entrega anterior de esta semana",
            area: .university,
            dueDate: date(day: 1)
        )
        let scheduledToday = LumaTask(
            title: "Programada hoy",
            area: .university,
            dueDate: date(day: 20),
            deadline: date(day: 3, hour: 18)
        )
        let deliveryTomorrow = LumaTask(
            title: "Entrega mañana",
            area: .university,
            dueDate: date(day: 4)
        )
        let deliveryNextWeek = LumaTask(
            title: "Entrega la semana próxima",
            area: .university,
            dueDate: date(day: 10, hour: 23)
        )
        let outsideWindow = LumaTask(
            title: "Más adelante",
            area: .university,
            deadline: date(day: 11)
        )

        let viewModel = InboxViewModel()
        viewModel.select(.week)
        let result = viewModel.filteredTasks(
            from: [outsideWindow, deliveryNextWeek, deliveryTomorrow, scheduledToday, deliveryEarlierThisWeek],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.title), [
            "Entrega anterior de esta semana",
            "Programada hoy",
            "Entrega mañana",
        ])
    }

    func testNoDateRequiresNeitherDeliveryNorCalendarDate() {
        let unscheduled = LumaTask(title: "Sin fecha", area: .home)
        let deliveryOnly = LumaTask(title: "Con entrega", area: .home, dueDate: date(day: 5))
        let calendarOnly = LumaTask(title: "Programada", area: .home, deadline: date(day: 5))

        let viewModel = InboxViewModel()
        viewModel.select(.noDate)

        XCTAssertEqual(
            viewModel.filteredTasks(from: [deliveryOnly, unscheduled, calendarOnly]).map(\.id),
            [unscheduled.id]
        )
    }

    func testIncludeCompletedWorksWithQuickAndAreaFilters() {
        let openQuick = LumaTask(title: "Rápida abierta", area: .home, estimatedMinutes: 20)
        let completedQuick = LumaTask(
            title: "Rápida hecha",
            area: .home,
            estimatedMinutes: 25,
            status: .completed,
            completedAt: date(day: 2)
        )
        let completedLong = LumaTask(
            title: "Larga hecha",
            area: .home,
            estimatedMinutes: 90,
            status: .completed,
            completedAt: date(day: 2)
        )
        let quickOtherArea = LumaTask(title: "Rápida de uni", area: .university, estimatedMinutes: 15)

        let viewModel = InboxViewModel()
        viewModel.select(.quick)
        viewModel.selectedArea = .home
        viewModel.showCompleted = true

        let result = viewModel.filteredTasks(
            from: [completedLong, quickOtherArea, completedQuick, openQuick]
        )
        XCTAssertEqual(Set(result.map(\.id)), Set([openQuick.id, completedQuick.id]))
    }

    func testLeavingCompletedFilterDoesNotLeakCompletedTasksIntoAll() {
        let pending = LumaTask(title: "Pendiente", area: .errands)
        let completed = LumaTask(title: "Hecha", area: .errands, status: .completed)
        let viewModel = InboxViewModel()

        viewModel.select(.completed)
        XCTAssertEqual(viewModel.filteredTasks(from: [pending, completed]).map(\.id), [completed.id])

        viewModel.select(.all)
        XCTAssertEqual(viewModel.filteredTasks(from: [pending, completed]).map(\.id), [pending.id])
    }

    func testEvaluationFilterRecognizesAcademicAndGeneratedStudyTasks() {
        let academic = LumaTask(
            title: "Parcial",
            area: .university,
            impact: .grade
        )
        let generatedStudy = LumaTask(
            title: "Repasar tema",
            area: .university,
            impact: .general,
            sourceTypeRaw: AcademicTaskSourceType.examStudy.rawValue
        )
        let generalUniversityTask = LumaTask(
            title: "Ordenar carpeta",
            area: .university,
            impact: .general
        )

        let viewModel = InboxViewModel()
        viewModel.select(.evaluations)
        let result = viewModel.filteredTasks(from: [generalUniversityTask, generatedStudy, academic])

        XCTAssertEqual(Set(result.map(\.id)), Set([academic.id, generatedStudy.id]))
    }

    func testLowEnergyAndBlockedFiltersUseTheirSpecificRules() {
        let blocked = LumaTask(title: "Tarea bloqueada", area: .university)
        let blocker = LumaTask(
            title: "Paso previo",
            area: .university,
            energy: .low,
            unlocksAnotherTask: true,
            unlocksTaskID: blocked.id
        )
        let unrelated = LumaTask(title: "Otra tarea", area: .home, energy: .medium)
        let tasks = [unrelated, blocked, blocker]
        let viewModel = InboxViewModel()

        viewModel.select(.lowEnergy)
        XCTAssertEqual(viewModel.filteredTasks(from: tasks).map(\.id), [blocker.id])

        viewModel.select(.blocked)
        XCTAssertEqual(viewModel.filteredTasks(from: tasks).map(\.id), [blocked.id])
    }

    func testResetRestoresPendingTasksFromEveryArea() {
        let university = LumaTask(title: "Uni", area: .university, energy: .low)
        let home = LumaTask(title: "Casa", area: .home)
        let completed = LumaTask(title: "Hecha", area: .home, status: .completed)
        let viewModel = InboxViewModel()
        viewModel.select(.lowEnergy)
        viewModel.selectedArea = .university
        viewModel.showCompleted = true

        viewModel.resetFilters()

        XCTAssertEqual(Set(viewModel.filteredTasks(from: [completed, home, university]).map(\.id)), Set([home.id, university.id]))
        XCTAssertFalse(viewModel.hasCustomFilters)
    }

    private func date(day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
}
