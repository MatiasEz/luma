@testable import Luma
import SwiftData
import XCTest

@MainActor
final class SharedPlanningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_142_400)
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }

    func testDueTodayRemainsActionableEvenWhenTargetWasYesterday() {
        let task = LumaTask(title: "Entrega", area: .university, dueDate: now, estimatedMinutes: 90, createdAt: now.addingTimeInterval(-10 * 86400))
        let planner = TaskPlanner(calendar: calendar)
        XCTAssertEqual(planner.recommendations(from: [task], now: now).first?.id, task.id)
        XCTAssertTrue(planner.overdueTasksNeedingReview(from: [task], now: now).isEmpty)
    }

    func testPrerequisiteInheritsUrgencyThroughAChain() {
        let delivery = LumaTask(title: "Enviar", area: .sideHustle, dueDate: now, energy: .high)
        let middle = LumaTask(title: "Revisar", area: .sideHustle, energy: .high, unlocksTaskID: delivery.id)
        let first = LumaTask(title: "Preparar", area: .sideHustle, energy: .high, unlocksTaskID: middle.id)
        let casual = LumaTask(title: "Ordenar", area: .home, energy: .low)
        let result = TaskPlanner(calendar: calendar).recommendations(from: [delivery, middle, casual, first], now: now, preference: .tired)
        XCTAssertEqual(result.first?.id, first.id)
        XCTAssertFalse(result.contains { $0.id == delivery.id || $0.id == middle.id })
    }

    func testWeightMattersWithOtherwiseIdenticalTasks() {
        let low = LumaTask(title: "A", area: .university, dueDate: now.addingTimeInterval(5 * 86400), impact: .grade, academicWeight: 5, createdAt: now)
        let high = LumaTask(title: "B", area: .university, dueDate: low.dueDate, impact: .grade, academicWeight: 40, createdAt: now)
        XCTAssertEqual(TaskPlanner(calendar: calendar).recommendations(from: [low, high], now: now, limit: 1).first?.id, high.id)
    }

    func testSingleUrgentPriorityGetsTwoDistinctSessions() {
        let task = LumaTask(title: "Entrega", area: .university, dueDate: now, estimatedMinutes: 90)
        let today = DailyPlanSnapshot(day: calendar.startOfDay(for: now), taskIDs: [task.id], energyPreference: .normal, suggestedMinutesByTaskID: [task.id: 45], restMinutes: 0)
        let plan = SharedPlanBuilder(calendar: calendar).build(tasks: [task], previous: .init(), todayPlan: today, todayBudget: 90, availability: [], preference: .normal, planner: TaskPlanner(calendar: calendar), now: now, horizon: 1)
        XCTAssertEqual(plan.blocks.map(\.minutes), [45, 45])
        XCTAssertEqual(Set(plan.blocks.map(\.id)).count, 2)
        XCTAssertTrue(plan.capacityIssues.isEmpty)
        XCTAssertEqual(task.focusedMinutes, 0, "Planning must not record work")
    }

    func testCapacityIsSharedAcrossTasksAndWarnsBeforeDeadline() {
        let due = calendar.date(byAdding: .day, value: 1, to: now)!
        let tasks = (0..<3).map { LumaTask(title: "Entrega \($0)", area: .university, dueDate: due, estimatedMinutes: 90) }
        let week = (1...7).map { DayAvailability(weekday: $0, isEnabled: true, startMinuteOfDay: 600, availableMinutes: 45) }
        let plan = SharedPlanBuilder(calendar: calendar).build(tasks: tasks, previous: .init(), todayPlan: nil, todayBudget: 0, availability: week, preference: .normal, planner: TaskPlanner(calendar: calendar), now: now, horizon: 2)
        XCTAssertLessThanOrEqual(plan.blocks.reduce(0) { $0 + $1.minutes }, 45)
        XCTAssertEqual(plan.capacityIssues.reduce(0) { $0 + $1.missingMinutes }, 270)
        XCTAssertTrue(plan.blocks.allSatisfy { $0.startMinute == nil })
    }

    func testStudyOrderAndStartDateAreRespected() {
        let source = UUID()
        let first = LumaTask(title: "Tema 1", area: .university, sourceID: source)
        first.planningDetails = TaskPlanningDetails(startDate: now, studyOrder: 0)
        let second = LumaTask(title: "Tema 2", area: .university, dueDate: now, sourceID: source)
        second.planningDetails = TaskPlanningDetails(startDate: now, studyOrder: 1)
        let future = LumaTask(title: "Futuro", area: .university)
        future.planningDetails = TaskPlanningDetails(startDate: now.addingTimeInterval(86400))
        let planner = TaskPlanner(calendar: calendar)
        XCTAssertEqual(planner.recommendations(from: [second, future, first], now: now).map(\.id), [first.id])
        first.markCompleted()
        XCTAssertEqual(planner.recommendations(from: [second, first], now: now).first?.id, second.id)
    }

    func testConfirmedDaySurvivesNewTaskAndTitleEdit() throws {
        let name = "LumaTests.shared.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(defaults: defaults, calendar: calendar, now: now)
        let task = LumaTask(title: "Original", area: .home)
        let planner = TaskPlanner(calendar: calendar)
        state.prepareDailyPlan(from: [task], planner: planner, inputFingerprint: "a", now: now)
        let original = state.dailyPlan
        task.title = "Nuevo título"
        let urgent = LumaTask(title: "Nueva", area: .university, dueDate: now)
        state.prepareDailyPlan(from: [task, urgent], planner: planner, inputFingerprint: "b", now: now)
        XCTAssertEqual(state.dailyPlan?.taskIDs, original?.taskIDs)
        XCTAssertEqual(state.dailyPlan?.suggestedMinutesByTaskID, original?.suggestedMinutesByTaskID)
    }

    func testActiveFocusRecoveryCapsElapsedAndExcludesPausedTime() {
        var snapshot = ActiveFocusSnapshot(id: UUID(), durationMinutes: 25, elapsedSeconds: 60, isRunning: true, checkpointAt: now, completed: false)
        XCTAssertEqual(snapshot.elapsed(at: now.addingTimeInterval(90)), 150)
        XCTAssertEqual(snapshot.elapsed(at: now.addingTimeInterval(7200)), 1500)
        snapshot.isRunning = false
        XCTAssertEqual(snapshot.elapsed(at: now.addingTimeInterval(90)), 60)
    }

    func testRestNeverTrainsWorkPreferences() {
        let sessions = (0..<6).map { _ in FocusSession(taskID: UUID(), taskTitle: "Pausa", area: .rest, plannedMinutes: 15, actualMinutes: 15, startedAt: now.addingTimeInterval(-900), endedAt: now, energyPreference: .normal) }
        XCTAssertFalse(BehaviorLearningEngine(calendar: calendar).profile(from: sessions, now: now).isReady)
    }

    func testPartialFocusKeepsRemainingMinutesAndStableFollowingBlock() throws {
        let name = "LumaTests.partial.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let task = LumaTask(title: "Entrega", area: .university, dueDate: now, estimatedMinutes: 90)
        let state = AppState(defaults: defaults, calendar: calendar, now: now)
        let planner = TaskPlanner(calendar: calendar, availableMinutes: 90)
        state.prepareDailyPlan(from: [task], planner: planner, now: now)
        state.refreshSharedPlan(tasks: [task], planner: planner, now: now)
        let original = state.workBlocks(on: now)
        XCTAssertEqual(original.count, 2)
        task.recordFocusSession(minutes: 10, at: now)
        let event = UUID()
        state.recordTimeSpent(eventID: event, minutes: 10, now: now)
        state.finishPlannedBlock(for: task.id, blockID: original[0].id, workedMinutes: 10, now: now)
        state.refreshSharedPlan(tasks: [task], planner: planner, now: now)
        let blocks = state.workBlocks(on: now)
        XCTAssertEqual(blocks.map(\.minutes), [10, 35, 45])
        XCTAssertEqual(blocks[2].id, original[1].id)
        XCTAssertEqual(state.dailyPlan?.suggestedMinutesByTaskID?[task.id], 35)
        XCTAssertEqual(state.remainingAvailableMinutes(now: now), 80)
        state.finishPlannedBlock(for: task.id, blockID: original[0].id, workedMinutes: 10, now: now)
        XCTAssertEqual(state.workBlocks(on: now), blocks)
    }

    func testOldFocusRecoveryCannotReplaceTodaysBudget() throws {
        let name = "LumaTests.oldFocus.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(defaults: defaults, calendar: calendar, now: now)
        state.ensureDailyTimeBudget(availableMinutes: 120, now: now)
        XCTAssertFalse(state.recordTimeSpent(eventID: UUID(), minutes: 25, now: now.addingTimeInterval(-86400)))
        XCTAssertEqual(state.remainingAvailableMinutes(now: now), 120)
    }

    func testChosenFutureWorkDayIsNotSilentlyPulledIntoToday() {
        let scheduled = now.addingTimeInterval(2 * 86400)
        let task = LumaTask(title: "Llamar", area: .errands, deadline: scheduled)
        let planner = TaskPlanner(calendar: calendar)
        XCTAssertTrue(planner.recommendations(from: [task], now: now).isEmpty)
        XCTAssertEqual(planner.recommendations(from: [task], now: scheduled).first?.id, task.id)
        let week = SharedPlanBuilder(calendar: calendar).build(tasks: [task], previous: .init(), todayPlan: nil,
            todayBudget: 120, availability: [], preference: .normal, planner: planner, now: now, horizon: 3)
        XCTAssertTrue(week.blocks.allSatisfy { calendar.isDate($0.day, inSameDayAs: scheduled) })
        XCTAssertEqual(task.deadline, scheduled)
    }
    func testExternalCommitmentIsRespectedAfterReturningToToday() throws {
        let name = "LumaTests.busy.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(defaults: defaults, calendar: calendar, now: now)
        let task = LumaTask(title: "Preparar", area: .home, estimatedMinutes: 45)
        let planner = TaskPlanner(calendar: calendar, availableMinutes: 120)
        state.prepareDailyPlan(from: [task], planner: planner, now: now)
        state.configureDailyAgenda(availabilityWindows: [.init(startMinuteOfDay: 600, endMinuteOfDay: 720)],
            tasks: [task], planner: planner, scheduler: DailyScheduler(calendar: calendar), now: now)
        state.refreshSharedPlan(tasks: [task], planner: planner, now: now,
            busyBlocks: [.init(title: "Turno", startMinuteOfDay: 600, endMinuteOfDay: 660)])
        XCTAssertEqual(state.workBlocks(on: now).first?.startMinute, 660)
        state.refreshSharedPlan(tasks: [task], planner: planner, now: now)
        XCTAssertEqual(state.workBlocks(on: now).first?.startMinute, 660)
        XCTAssertEqual(state.remainingAvailableMinutes(now: now), 120, "Net free minutes must not be subtracted twice")
        state.refreshSharedPlan(tasks: [task], planner: planner, now: now, busyBlocks: [])
        XCTAssertEqual(state.workBlocks(on: now).first?.startMinute, 600)
    }

    func testWeeklyShortfallIsMeasuredBeforeDeliveryDay() {
        let due = now.addingTimeInterval(4 * 86400)
        let tasks = (0..<4).map { LumaTask(title: "Entrega \($0)", area: .university, dueDate: due, estimatedMinutes: 180) }
        let availability = (1...7).map { DayAvailability(weekday: $0, isEnabled: true, startMinuteOfDay: 600, availableMinutes: 120) }
        let today = DailyPlanSnapshot(day: calendar.startOfDay(for: now), taskIDs: Array(tasks.prefix(3).map(\.id)), energyPreference: .normal,
            suggestedMinutesByTaskID: [tasks[0].id: 45, tasks[1].id: 45, tasks[2].id: 15], restMinutes: 15)
        let result = SharedPlanBuilder(calendar: calendar).build(tasks: tasks, previous: .init(), todayPlan: today,
            todayBudget: 120, availability: availability, preference: .normal,
            planner: TaskPlanner(calendar: calendar, restCounts: true), now: now, horizon: 5)
        XCTAssertEqual(result.capacityIssues.reduce(0) { $0 + $1.missingMinutes }, 300)
        XCTAssertEqual(result.blocks.filter { $0.day < calendar.startOfDay(for: due) }.reduce(0) { $0 + $1.minutes }, 420)
    }

    func testPreparationIsVisibleWhenItsStartIsMoreThanTwoWeeksAway() {
        let start = calendar.startOfDay(for: now.addingTimeInterval(24 * 86400))
        let task = LumaTask(title: "Preparar examen", area: .university, dueDate: now.addingTimeInterval(38 * 86400), estimatedMinutes: 120)
        task.planningDetails = TaskPlanningDetails(startDate: start)
        let result = SharedPlanBuilder(calendar: calendar).build(tasks: [task], previous: .init(), todayPlan: nil,
            todayBudget: 0, availability: [], preference: .normal, planner: TaskPlanner(calendar: calendar), now: now)
        XCTAssertFalse(result.blocks.isEmpty)
        XCTAssertTrue(result.blocks.allSatisfy { $0.day >= start })
        XCTAssertTrue(result.capacityIssues.isEmpty)
    }

    func testFocusClockPreservesFractionalTicksAndTimeAwayFromScreen() throws {
        let name = "LumaTests.clock.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let vm = FocusRoomViewModel(defaults: defaults, now: now)
        vm.isRunning = true
        for tick in 1...10 { vm.checkpoint(now: now.addingTimeInterval(Double(tick) * 0.6), advance: true) }
        XCTAssertEqual(vm.elapsedSeconds, 6)
        vm.checkpoint(now: now.addingTimeInterval(126), advance: true)
        XCTAssertEqual(vm.elapsedSeconds, 126)
        vm.isRunning = false
        vm.checkpoint(now: now.addingTimeInterval(126))
        vm.checkpoint(now: now.addingTimeInterval(300), advance: true)
        XCTAssertEqual(vm.elapsedSeconds, 126)
        let recovered = FocusRoomViewModel(defaults: defaults, now: now.addingTimeInterval(500))
        XCTAssertEqual(recovered.elapsedSeconds, 126)
    }

}
