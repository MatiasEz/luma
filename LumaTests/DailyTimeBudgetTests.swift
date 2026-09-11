@testable import Luma
import XCTest

@MainActor
final class DailyTimeBudgetTests: XCTestCase {
    func testAdditionalTimeUsesTheBalanceAfterActualWork() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()

        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 45, now: setup.now))
        state.setRemainingAvailableMinutes(
            state.remainingAvailableMinutes(now: setup.now) + 30,
            now: setup.now
        )

        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 105)
        let budget = try XCTUnwrap(state.dailyTimeBudget)
        XCTAssertEqual(budget.allocatedMinutes, 150)
        XCTAssertEqual(budget.consumedMinutes, 45)
        XCTAssertEqual(budget.remainingMinutes, 105)
    }

    func testRecordedWorkRemainsIdempotentAfterReopening() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let eventID = UUID()

        XCTAssertTrue(state.recordTimeSpent(
            eventID: eventID,
            minutes: 45,
            initialAvailableMinutes: 120,
            now: setup.now
        ))
        state.setRemainingAvailableMinutes(105, now: setup.now)
        XCTAssertFalse(state.recordTimeSpent(eventID: eventID, minutes: 45, now: setup.now))

        let reopened = setup.makeState()
        XCTAssertFalse(reopened.recordTimeSpent(eventID: eventID, minutes: 45, now: setup.now))
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: setup.now), 105)
        let budget = try XCTUnwrap(reopened.dailyTimeBudget)
        XCTAssertEqual(budget.consumedMinutesByEventID.count, 1)
        XCTAssertEqual(budget.consumedMinutesByEventID[eventID], 45)
    }

    func testUndoReturnsWorkedMinutesWithoutRemovingAdditionalTime() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let eventID = UUID()

        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: eventID, minutes: 45, now: setup.now))
        state.setRemainingAvailableMinutes(105, now: setup.now)

        XCTAssertTrue(state.undoTimeSpent(eventID: eventID, now: setup.now))
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 150)
        XCTAssertFalse(state.undoTimeSpent(eventID: eventID, now: setup.now))
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 150)

        let reopened = setup.makeState()
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: setup.now), 150)
        XCTAssertEqual(reopened.dailyTimeBudget?.consumedMinutes, 0)
        XCTAssertFalse(reopened.undoTimeSpent(eventID: eventID, now: setup.now))
    }

    func testConfirmingRemainingTimeDoesNotSubtractPastWorkAgain() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()

        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 45, now: setup.now))
        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 75)

        state.setRemainingAvailableMinutes(60, now: setup.now)
        state.setRemainingAvailableMinutes(60, now: setup.now)

        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 60)
        XCTAssertEqual(state.dailyTimeBudget?.allocatedMinutes, 105)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutes, 45)
    }

    func testReadingFallbackDoesNotInitializeOrReserveTime() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()

        XCTAssertNil(state.dailyTimeBudget)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 120)
        XCTAssertEqual(state.remainingAvailableMinutes(fallback: 90, now: setup.now), 90)
        XCTAssertEqual(state.remainingAvailableMinutes(fallback: 0, now: setup.now), 0)
        XCTAssertEqual(state.remainingAvailableMinutes(fallback: -30, now: setup.now), 0)
        XCTAssertNil(state.dailyTimeBudget)
        XCTAssertNil(setup.makeState().dailyTimeBudget)
    }

    func testZeroAndNegativeWorkCannotConsumeOrCreditTime() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()

        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertFalse(state.recordTimeSpent(eventID: UUID(), minutes: 0, now: setup.now))
        XCTAssertFalse(state.recordTimeSpent(eventID: UUID(), minutes: -45, now: setup.now))

        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 120)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutesByEventID.count, 0)

        state.setRemainingAvailableMinutes(-20, now: setup.now)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 0)
    }

    func testExtraTimeCanBeAddedAfterAnOverrunWithoutLosingActualWork() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()

        state.ensureDailyTimeBudget(availableMinutes: 30, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 45, now: setup.now))
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 0)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutes, 45)

        state.setRemainingAvailableMinutes(
            state.remainingAvailableMinutes(now: setup.now) + 30,
            now: setup.now
        )
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 30)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutes, 45)
    }

    func testNewDayDoesNotInheritConsumptionOrUndoCreditFromYesterday() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let yesterdayEventID = UUID()
        let tomorrow = try XCTUnwrap(setup.calendar.date(byAdding: .day, value: 1, to: setup.now))

        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: yesterdayEventID, minutes: 45, now: setup.now))

        XCTAssertEqual(state.remainingAvailableMinutes(fallback: 90, now: tomorrow), 90)
        XCTAssertFalse(state.undoTimeSpent(eventID: yesterdayEventID, now: tomorrow))
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 75)

        state.ensureDailyTimeBudget(availableMinutes: 90, now: tomorrow)
        XCTAssertEqual(state.dailyTimeBudget?.day, setup.calendar.startOfDay(for: tomorrow))
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutes, 0)
        XCTAssertEqual(state.remainingAvailableMinutes(now: tomorrow), 90)
        XCTAssertFalse(state.undoTimeSpent(eventID: yesterdayEventID, now: tomorrow))

        let reopened = setup.makeState(now: tomorrow)
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: tomorrow), 90)
        XCTAssertEqual(reopened.dailyTimeBudget?.consumedMinutes, 0)
    }

    func testReplanUndoPreservesWorkRecordedAfterTheReplan() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let firstEventID = UUID()
        let laterEventID = UUID()

        state.ensureDailyTimeBudget(availableMinutes: 120, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: firstEventID, minutes: 45, now: setup.now))
        let remaining = state.remainingAvailableMinutes(now: setup.now)
        var proposal = ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: "Tengo treinta minutos más",
            tasks: [],
            currentPlan: state.dailyPlan,
            currentAgenda: state.dailyAgenda,
            currentEnergy: .normal,
            proposedEnergy: .normal,
            currentAvailableMinutes: remaining,
            proposedAvailableMinutes: remaining + 30,
            planner: TaskPlanner(calendar: setup.calendar, availableMinutes: remaining),
            scheduler: DailyScheduler(calendar: setup.calendar),
            now: setup.now
        )
        // The builder uses Calendar.current; keep this ledger test independent
        // of the test runner's time zone.
        proposal.day = setup.calendar.startOfDay(for: setup.now)

        state.applyReplan(proposal)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 105)
        XCTAssertTrue(state.recordTimeSpent(eventID: laterEventID, minutes: 15, now: setup.now))
        state.restoreReplan(proposal)

        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 60)
        let budget = try XCTUnwrap(state.dailyTimeBudget)
        XCTAssertEqual(budget.allocatedMinutes, 120)
        XCTAssertEqual(budget.consumedMinutesByEventID[firstEventID], 45)
        XCTAssertEqual(budget.consumedMinutesByEventID[laterEventID], 15)
    }

    func testLegacyPlanDecodesWithoutRestOrInventedConsumption() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let taskID = UUID()
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "day": setup.now.timeIntervalSinceReferenceDate,
            "taskIDs": [taskID.uuidString],
            "energyPreference": EnergyPreference.normal.rawValue,
        ])
        setup.defaults.set(legacyData, forKey: "lumaDailyPlanSnapshot")

        let state = setup.makeState()
        let plan = try XCTUnwrap(state.dailyPlan)
        XCTAssertEqual(plan.taskIDs, [taskID])
        XCTAssertNil(plan.restMinutes)
        XCTAssertNil(state.dailyTimeBudget)
        XCTAssertEqual(state.remainingAvailableMinutes(fallback: 90, now: setup.now), 90)

        state.ensureDailyTimeBudget(availableMinutes: 90, now: setup.now)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutes, 0)
        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 20, now: setup.now))

        let reopened = setup.makeState()
        reopened.ensureDailyTimeBudget(availableMinutes: 90, now: setup.now)
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: setup.now), 70)
    }

    func testReplanGrantsThirtyUsableMinutesAfterAnOverrun() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let eventID = UUID()

        state.ensureDailyTimeBudget(availableMinutes: 30, now: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: eventID, minutes: 45, now: setup.now))
        let remaining = state.remainingAvailableMinutes(now: setup.now)
        XCTAssertEqual(remaining, 0)

        var proposal = ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: "Tengo treinta minutos más",
            tasks: [],
            currentPlan: state.dailyPlan,
            currentAgenda: state.dailyAgenda,
            currentEnergy: .normal,
            proposedEnergy: .normal,
            currentAvailableMinutes: remaining,
            proposedAvailableMinutes: remaining + 30,
            timeBudget: state.dailyTimeBudget,
            planner: TaskPlanner(calendar: setup.calendar, availableMinutes: remaining),
            scheduler: DailyScheduler(calendar: setup.calendar),
            now: setup.now
        )
        proposal.day = setup.calendar.startOfDay(for: setup.now)

        state.applyReplan(proposal)

        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 30)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutesByEventID[eventID], 45)
        XCTAssertEqual(setup.makeState().remainingAvailableMinutes(now: setup.now), 30)

        state.restoreReplan(proposal)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 0)
        XCTAssertEqual(state.dailyTimeBudget?.allocatedMinutes, 30)
        XCTAssertEqual(state.dailyTimeBudget?.consumedMinutes, 45)
    }

    func testTiredDayKeepsItsTenMinuteRestAfterWorkReopeningAndUndo() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let work = LumaTask(
            title: "Ordenar apuntes",
            area: .university,
            estimatedMinutes: 90,
            energy: .low,
            createdAt: setup.now,
            updatedAt: setup.now
        )
        let rest = LumaTask(
            title: "Descanso de hoy",
            area: .rest,
            estimatedMinutes: 15,
            energy: .low,
            createdAt: setup.now,
            updatedAt: setup.now,
            sourceTypeRaw: AcademicTaskSourceType.rest.rawValue,
            sourceOccurrenceDate: setup.now
        )
        let tasks = [work, rest]
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 30, restCounts: true)
        state.replanDaily(from: tasks, planner: planner, preference: .tired, now: setup.now)

        let initialWork = state.dailyRecommendations(from: tasks, planner: planner, now: setup.now)
        XCTAssertEqual(initialWork.map(\.task.id), [work.id])
        XCTAssertEqual(initialWork.map(\.suggestedMinutes), [20])
        XCTAssertEqual(state.dailyPlan?.restMinutes, 10)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 30)

        work.recordFocusSession(minutes: 20, at: setup.now)
        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 20, now: setup.now))
        state.finishPlannedBlock(for: work.id)

        let reopened = setup.makeState()
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: setup.now), 10)
        XCTAssertEqual(reopened.dailyPlan?.restMinutes, 10)
        XCTAssertTrue(reopened.dailyRecommendations(from: tasks, planner: planner, now: setup.now).isEmpty)
        let pause = try XCTUnwrap(planner.restRecommendation(
            from: tasks,
            now: setup.now,
            preference: reopened.energyPreference,
            budgetOverride: reopened.remainingAvailableMinutes(now: setup.now),
            savedMinutes: reopened.dailyPlan?.restMinutes
        ))
        XCTAssertEqual(pause.task.id, rest.id)
        XCTAssertEqual(pause.suggestedMinutes, 10)

        let restEventID = UUID()
        XCTAssertTrue(reopened.recordTimeSpent(eventID: restEventID, minutes: pause.suggestedMinutes, now: setup.now))
        rest.markCompleted()
        reopened.finishPlannedBlock(for: rest.id)
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: setup.now), 0)

        XCTAssertTrue(reopened.undoTimeSpent(eventID: restEventID, now: setup.now))
        rest.restore()
        XCTAssertFalse(reopened.undoTimeSpent(eventID: restEventID, now: setup.now))
        XCTAssertEqual(reopened.remainingAvailableMinutes(now: setup.now), 10)
        XCTAssertEqual(reopened.dailyTimeBudget?.consumedMinutes, 20)
        XCTAssertEqual(planner.restRecommendation(
            from: tasks,
            now: setup.now,
            preference: reopened.energyPreference,
            budgetOverride: reopened.remainingAvailableMinutes(now: setup.now),
            savedMinutes: reopened.dailyPlan?.restMinutes
        )?.suggestedMinutes, 10)
        XCTAssertEqual(setup.makeState().remainingAvailableMinutes(now: setup.now), 10)
    }

    func testDashboardDoesNotOfferRestUsingAnOutdatedPlannerBudget() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let work = LumaTask(
            title: "Ordenar apuntes",
            area: .university,
            estimatedMinutes: 90,
            energy: .low,
            createdAt: setup.now,
            updatedAt: setup.now
        )
        let rest = LumaTask(
            title: "Descanso de hoy",
            area: .rest,
            estimatedMinutes: 15,
            energy: .low,
            createdAt: setup.now,
            updatedAt: setup.now,
            sourceTypeRaw: AcademicTaskSourceType.rest.rawValue,
            sourceOccurrenceDate: setup.now
        )
        let tasks = [work, rest]
        let originalPlanner = TaskPlanner(calendar: setup.calendar, availableMinutes: 30, restCounts: true)
        state.replanDaily(from: tasks, planner: originalPlanner, preference: .tired, now: setup.now)
        let dashboard = DashboardViewModel()
        dashboard.refreshPresentation(tasks: tasks, planner: originalPlanner, appState: state, now: setup.now)
        XCTAssertEqual(dashboard.visibleRecommendations.map(\.suggestedMinutes), [20])
        XCTAssertEqual(dashboard.restRecommendation?.suggestedMinutes, 10)

        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 30, now: setup.now))
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 0)
        XCTAssertEqual(originalPlanner.availableTimeBudget, 30)
        dashboard.refreshPresentation(tasks: tasks, planner: originalPlanner, appState: state, now: setup.now)

        XCTAssertTrue(dashboard.visibleRecommendations.isEmpty)
        XCTAssertNil(dashboard.restRecommendation)
        XCTAssertNil(dashboard.optionalRecommendation)
    }

    func testYesterdaysProposalCannotReplaceTodaysBudgetOrPlan() throws {
        let setup = try makeSetup()
        defer { setup.defaults.removePersistentDomain(forName: setup.suiteName) }
        let state = setup.makeState()
        let yesterday = try XCTUnwrap(setup.calendar.date(byAdding: .day, value: -1, to: setup.now))

        state.ensureDailyTimeBudget(availableMinutes: 120, now: yesterday)
        XCTAssertTrue(state.recordTimeSpent(eventID: UUID(), minutes: 45, now: yesterday))
        var oldProposal = ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: "Propuesta pendiente de ayer",
            tasks: [],
            currentPlan: state.dailyPlan,
            currentAgenda: state.dailyAgenda,
            currentEnergy: .normal,
            proposedEnergy: .energized,
            currentAvailableMinutes: state.remainingAvailableMinutes(now: yesterday),
            proposedAvailableMinutes: 105,
            timeBudget: state.dailyTimeBudget,
            planner: TaskPlanner(calendar: setup.calendar, availableMinutes: 75),
            scheduler: DailyScheduler(calendar: setup.calendar),
            now: yesterday
        )
        oldProposal.day = setup.calendar.startOfDay(for: yesterday)

        state.ensureDailyTimeBudget(availableMinutes: 90, now: setup.now)
        let todaysWorkID = UUID()
        XCTAssertTrue(state.recordTimeSpent(eventID: todaysWorkID, minutes: 20, now: setup.now))
        state.replanDaily(
            from: [],
            planner: TaskPlanner(calendar: setup.calendar, availableMinutes: 90),
            preference: .tired,
            now: setup.now
        )
        let currentBudget = state.dailyTimeBudget
        let currentPlan = state.dailyPlan
        let currentAgenda = state.dailyAgenda
        let currentRevision = state.planRevision

        state.applyReplan(oldProposal)
        XCTAssertEqual(state.dailyTimeBudget, currentBudget)
        XCTAssertEqual(state.dailyPlan, currentPlan)
        XCTAssertEqual(state.dailyAgenda, currentAgenda)
        XCTAssertEqual(state.energyPreference, .tired)
        XCTAssertEqual(state.planRevision, currentRevision)

        state.restoreReplan(oldProposal)
        XCTAssertEqual(state.dailyTimeBudget, currentBudget)
        XCTAssertEqual(state.dailyPlan, currentPlan)
        XCTAssertEqual(state.dailyAgenda, currentAgenda)
        XCTAssertEqual(state.energyPreference, .tired)
        XCTAssertEqual(state.planRevision, currentRevision)
        XCTAssertEqual(state.remainingAvailableMinutes(now: setup.now), 70)
        XCTAssertEqual(setup.makeState().dailyTimeBudget?.consumedMinutesByEventID[todaysWorkID], 20)
    }

    private struct Setup {
        let defaults: UserDefaults
        let suiteName: String
        let calendar: Calendar
        let now: Date

        @MainActor
        func makeState(now: Date? = nil) -> AppState {
            AppState(defaults: defaults, calendar: calendar, now: now ?? self.now)
        }
    }

    private func makeSetup() throws -> Setup {
        let suiteName = "DailyTimeBudgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -3 * 60 * 60))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 9
        )))
        return Setup(defaults: defaults, suiteName: suiteName, calendar: calendar, now: now)
    }
}
