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

    func testAssignedBlocksKeepTheirMinutesWithOneRestReservation() throws {
        let now = Date.now
        let tasks = makeTasks(now: now) + [LumaTask(
            title: "Descanso",
            area: .hobbies,
            estimatedMinutes: 15,
            energy: .low,
            impact: .wellbeing,
            sourceTypeRaw: AcademicTaskSourceType.rest.rawValue,
            sourceOccurrenceDate: now
        )]
        let planner = TaskPlanner(availableMinutes: 120, restCounts: true)
        let recommendations = planner.recommendations(from: tasks, now: now)
        XCTAssertEqual(recommendations.map(\.suggestedMinutes), [45, 45, 15])
        let expectedMinutes = Dictionary(uniqueKeysWithValues: recommendations.map {
            ($0.id, $0.suggestedMinutes)
        })
        let suiteName = "DailyAgendaRestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults, now: now)
        let scheduler = DailyScheduler()
        _ = state.prepareDailyPlan(from: tasks, planner: planner, now: now)
        state.configureDailyAgenda(
            availableMinutes: 120,
            startMinuteOfDay: 9 * 60,
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            now: now
        )
        let blocks = try XCTUnwrap(state.dailyAgenda?.blocks)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: blocks.map { ($0.taskID, $0.durationMinutes) }), expectedMinutes)
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 105)

        let proposal = ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: "Mantener el plan",
            tasks: tasks,
            currentPlan: state.dailyPlan,
            currentAgenda: state.dailyAgenda,
            currentEnergy: .normal,
            proposedEnergy: .normal,
            currentAvailableMinutes: 120,
            planner: planner,
            scheduler: scheduler,
            now: now
        )
        XCTAssertEqual(proposal.afterRestMinutes, 15)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: proposal.afterBlocks.map { ($0.taskID, $0.durationMinutes) }), expectedMinutes)

        let busy = BusyTimeBlock(title: "Clase", startMinuteOfDay: 9 * 60 + 30, endMinuteOfDay: 10 * 60 + 30)
        let aroundClass = scheduler.schedule(
            recommendations: recommendations,
            availabilityWindows: [AvailabilityWindow(startMinuteOfDay: 9 * 60, endMinuteOfDay: 12 * 60)],
            busyBlocks: [busy],
            reservedRestMinutes: 15
        )
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: aroundClass.map { ($0.taskID, $0.durationMinutes) }), expectedMinutes)
        XCTAssertTrue(aroundClass.allSatisfy {
            $0.endMinuteOfDay <= busy.startMinuteOfDay || $0.startMinuteOfDay >= busy.endMinuteOfDay
        })
    }

    func testAssignedShortBlocksDoNotCreateExtraTime() {
        let task = makeTasks(now: .now)[0]
        let scheduler = DailyScheduler()
        for minutes in [0, 5, 10] {
            let recommendations = [PlanRecommendation(task: task, score: 1, reason: "Avance breve", suggestedMinutes: minutes)]
            let blocks = scheduler.schedule(
                recommendations: recommendations,
                availableMinutes: minutes,
                startMinuteOfDay: 9 * 60,
                reservedRestMinutes: 0
            )
            XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, minutes)
            XCTAssertEqual(blocks.count, minutes == 0 ? 0 : 1)
        }
        XCTAssertTrue(scheduler.schedule(
            recommendations: makeRecommendations(),
            availableMinutes: 0,
            startMinuteOfDay: 9 * 60
        ).isEmpty)
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
                dueDate: now.addingTimeInterval(86400),
                estimatedMinutes: 45,
                energy: .high,
                impact: .grade,
                academicWeight: 30
            ),
            LumaTask(
                title: "Enviar cotización",
                area: .sideHustle,
                dueDate: now.addingTimeInterval(2 * 86400),
                estimatedMinutes: 45,
                energy: .medium,
                impact: .money
            ),
            LumaTask(
                title: "Ordenar papeles",
                area: .errands,
                dueDate: now.addingTimeInterval(3 * 86400),
                estimatedMinutes: 45,
                energy: .low,
                impact: .urgency
            ),
        ]
    }
}
