@testable import Luma
import XCTest

@MainActor
final class DailyAgendaTests: XCTestCase {
    func testThirtyMinuteAgendaKeepsOnlyTheFirstPriority() {
        let recommendations = makeRecommendations()
        let blocks = DailyScheduler().schedule(
            recommendations: recommendations,
            availableMinutes: 30,
            startMinuteOfDay: 16 * 60
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.taskID, recommendations.first?.task.id)
        XCTAssertEqual(blocks.first?.durationMinutes, 30)
        XCTAssertEqual(blocks.first?.startMinuteOfDay, 16 * 60)
    }

    func testTwoHourAgendaFitsThreePrioritiesAndBreaks() throws {
        let blocks = DailyScheduler().schedule(
            recommendations: makeRecommendations(),
            availableMinutes: 120,
            startMinuteOfDay: 9 * 60
        )

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1].startMinuteOfDay - blocks[0].endMinuteOfDay, 10)
        XCTAssertEqual(blocks[2].startMinuteOfDay - blocks[1].endMinuteOfDay, 10)
        XCTAssertLessThanOrEqual(try XCTUnwrap(blocks.last).endMinuteOfDay - 9 * 60, 120)
    }

    func testAvailabilityPhraseDetectsTimeStartAndEnergy() {
        let draft = NaturalLanguageAgendaParser().parse(
            "Hoy tengo una hora desde las 16 y estoy cansada"
        )

        XCTAssertEqual(draft.availableMinutes, 60)
        XCTAssertEqual(draft.startMinuteOfDay, 16 * 60)
        XCTAssertEqual(draft.energyPreference, .tired)
    }

    func testAvailabilityPhraseDetectsMultipleWindows() throws {
        let draft = NaturalLanguageAgendaParser().parse(
            "Hoy puedo de 10 a 13 y después de 17 a 20"
        )

        let windows = try XCTUnwrap(draft.availabilityWindows)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].startMinuteOfDay, 10 * 60)
        XCTAssertEqual(windows[0].endMinuteOfDay, 13 * 60)
        XCTAssertEqual(windows[1].startMinuteOfDay, 17 * 60)
        XCTAssertEqual(windows[1].endMinuteOfDay, 20 * 60)
        XCTAssertEqual(draft.availableMinutes, 360)
    }

    func testSchedulerUsesSeparateAvailabilityWindows() throws {
        let blocks = DailyScheduler().schedule(
            recommendations: makeRecommendations(),
            availabilityWindows: [
                AvailabilityWindow(startMinuteOfDay: 10 * 60, endMinuteOfDay: 10 * 60 + 45),
                AvailabilityWindow(startMinuteOfDay: 17 * 60, endMinuteOfDay: 19 * 60),
            ]
        )

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].startMinuteOfDay, 10 * 60)
        XCTAssertEqual(blocks[1].startMinuteOfDay, 17 * 60)
        XCTAssertGreaterThanOrEqual(blocks[2].startMinuteOfDay, blocks[1].endMinuteOfDay)
        XCTAssertLessThanOrEqual(try XCTUnwrap(blocks.last).endMinuteOfDay, 19 * 60)
    }

    func testNewDayWaitsForConfirmedAvailability() throws {
        let suiteName = "DailyAgendaDynamicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        let tasks = makeTasks(now: .now)
        let planner = TaskPlanner()

        _ = state.prepareDailyPlan(from: tasks, planner: planner)
        state.prepareDailyAgenda(
            from: tasks,
            planner: planner,
            scheduler: DailyScheduler()
        )

        XCTAssertFalse(state.isTodayAvailabilityConfirmed)
        XCTAssertEqual(state.dailyAgenda?.availableMinutes, 0)
        XCTAssertTrue(state.dailyAgenda?.blocks.isEmpty == true)
    }

    func testAgendaAndFocusProgressPersistInTheirModels() throws {
        let suiteName = "DailyAgendaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 9))
        )
        let tasks = makeTasks(now: now)
        let planner = TaskPlanner(calendar: calendar)
        let scheduler = DailyScheduler(calendar: calendar)
        let state = AppState(defaults: defaults, calendar: calendar, now: now)

        _ = state.prepareDailyPlan(from: tasks, planner: planner, now: now)
        state.configureDailyAgenda(
            availableMinutes: 90,
            startMinuteOfDay: 14 * 60 + 30,
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            now: now
        )
        tasks[0].recordFocusSession(minutes: 25, at: now)

        let restored = AppState(defaults: defaults, calendar: calendar, now: now)
        XCTAssertEqual(restored.dailyAgenda, state.dailyAgenda)
        XCTAssertEqual(restored.dailyAgenda?.availableMinutes, 90)
        XCTAssertEqual(restored.dailyAgenda?.startMinuteOfDay, 14 * 60 + 30)
        XCTAssertEqual(tasks[0].focusedMinutes, 25)
        XCTAssertEqual(tasks[0].remainingEstimatedMinutes, 20)
    }

    private func makeRecommendations() -> [PlanRecommendation] {
        TaskPlanner().recommendations(from: makeTasks(now: .now))
    }

    private func makeTasks(now: Date) -> [LumaTask] {
        [
            LumaTask(
                title: "Entrega importante",
                area: .university,
                deadline: now.addingTimeInterval(86400),
                estimatedMinutes: 45,
                energy: .high,
                impact: .grade,
                academicWeight: 30
            ),
            LumaTask(
                title: "Enviar cotización",
                area: .sideHustle,
                deadline: now.addingTimeInterval(2 * 86400),
                estimatedMinutes: 45,
                energy: .medium,
                impact: .money
            ),
            LumaTask(
                title: "Ordenar papeles",
                area: .errands,
                deadline: now.addingTimeInterval(3 * 86400),
                estimatedMinutes: 45,
                energy: .low,
                impact: .urgency
            ),
        ]
    }
}
