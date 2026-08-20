@testable import Luma
import XCTest

@MainActor
final class BehaviorLearningTests: XCTestCase {
    func testProfileWaitsForFiveSessionsAndFindsRhythm() throws {
        let setup = makeSetup()
        let sessions = (0 ..< 5).map { index in
            makeSession(
                now: setup.now,
                dayOffset: -index,
                hour: 10,
                actualMinutes: 25,
                completed: index < 4
            )
        }

        let profile = BehaviorLearningEngine(calendar: setup.calendar)
            .profile(from: sessions, now: setup.now)

        XCTAssertTrue(profile.isReady)
        XCTAssertEqual(profile.sessionCount, 5)
        XCTAssertEqual(profile.preferredBlockMinutes, 25)
        XCTAssertEqual(profile.bestStartHour, 10)
        XCTAssertEqual(profile.topArea, .university)
        XCTAssertEqual(profile.taskCompletionRate, 0.8, accuracy: 0.001)
    }

    func testIgnoredSessionsDoNotInfluenceProfile() {
        let setup = makeSetup()
        let usable = makeSession(now: setup.now, dayOffset: 0, hour: 9, actualMinutes: 25)
        let ignored = makeSession(now: setup.now, dayOffset: 0, hour: 18, actualMinutes: 60)
        ignored.ignoredFromLearning = true

        let profile = BehaviorLearningEngine(calendar: setup.calendar)
            .profile(from: [usable, ignored], now: setup.now)

        XCTAssertEqual(profile.sessionCount, 1)
        XCTAssertEqual(profile.totalMinutes, 25)
        XCTAssertEqual(profile.bestStartHour, 9)
    }

    func testReadyProfileChangesSuggestedBlockWithoutOverridingPriorityRules() {
        let setup = makeSetup()
        let sessions = (0 ..< 5).map { index in
            makeSession(now: setup.now, dayOffset: -index, hour: 10, actualMinutes: 25)
        }
        let profile = BehaviorLearningEngine(calendar: setup.calendar)
            .profile(from: sessions, now: setup.now)
        let task = LumaTask(
            title: "Preparar entrega",
            area: .university,
            deadline: setup.now.addingTimeInterval(2 * 86400),
            estimatedMinutes: 90,
            energy: .high,
            impact: .grade
        )

        let recommendation = TaskPlanner(
            calendar: setup.calendar,
            rhythmProfile: profile
        ).recommendations(from: [task], now: setup.now).first

        XCTAssertEqual(recommendation?.suggestedMinutes, 25)
    }

    func testUserBlockOverrideWinsOverLearnedDuration() {
        let setup = makeSetup()
        let sessions = (0 ..< 5).map { index in
            makeSession(now: setup.now, dayOffset: -index, hour: 10, actualMinutes: 25)
        }
        let profile = BehaviorLearningEngine(calendar: setup.calendar)
            .profile(from: sessions, now: setup.now)
        let task = LumaTask(
            title: "Trabajo profundo",
            area: .university,
            estimatedMinutes: 90,
            energy: .high,
            impact: .grade
        )

        let recommendation = TaskPlanner(
            calendar: setup.calendar,
            rhythmProfile: profile,
            preferredBlockOverride: 45
        ).recommendations(from: [task], now: setup.now).first

        XCTAssertEqual(recommendation?.suggestedMinutes, 45)
    }

    private func makeSetup() -> (calendar: Calendar, now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 18, hour: 20)
        )!
        return (calendar, now)
    }

    private func makeSession(
        now: Date,
        dayOffset: Int,
        hour: Int,
        actualMinutes: Int,
        completed: Bool = true
    ) -> FocusSession {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return FocusSession(
            taskID: UUID(),
            taskTitle: "Sesión de estudio",
            area: .university,
            plannedMinutes: 25,
            actualMinutes: actualMinutes,
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(actualMinutes * 60)),
            energyPreference: .normal,
            completedTask: completed
        )
    }
}
