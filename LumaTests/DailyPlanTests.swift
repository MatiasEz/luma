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
