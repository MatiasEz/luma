@testable import Luma
import XCTest

@MainActor
final class FivePhaseIntegrationTests: XCTestCase {
    func testAgendaStaysInsideAvailabilityWhenCalendarConflicts() throws {
        let task = LumaTask(
            title: "Preparar entrega",
            area: .university,
            estimatedMinutes: 45,
            energy: .medium,
            impact: .grade
        )
        let recommendation = try XCTUnwrap(TaskPlanner().recommendations(from: [task]).first)
        let blocks = DailyScheduler().schedule(
            recommendations: [recommendation],
            availableMinutes: 45,
            startMinuteOfDay: 17 * 60,
            busyBlocks: [
                BusyTimeBlock(
                    title: "Clase",
                    startMinuteOfDay: 17 * 60 + 15,
                    endMinuteOfDay: 18 * 60
                ),
            ]
        )

        XCTAssertEqual(blocks.first?.startMinuteOfDay, 17 * 60)
        XCTAssertEqual(blocks.first?.durationMinutes, 15)
        XCTAssertLessThanOrEqual(try XCTUnwrap(blocks.first).endMinuteOfDay, 17 * 60 + 15)
    }

    func testWeeklyAvailabilityPersistsLocally() throws {
        let suite = "FivePhaseIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        var monday = try XCTUnwrap(state.weeklyAvailability.first(where: { $0.weekday == 2 }))
        monday.startMinuteOfDay = 19 * 60
        monday.availableMinutes = 90
        state.updateAvailability(monday)
        state.completeOnboarding()

        let restored = AppState(defaults: defaults)
        let restoredMonday = try XCTUnwrap(restored.weeklyAvailability.first(where: { $0.weekday == 2 }))
        XCTAssertEqual(restoredMonday.startMinuteOfDay, 19 * 60)
        XCTAssertEqual(restoredMonday.availableMinutes, 90)
        XCTAssertTrue(restored.onboardingCompleted)
    }

    func testBackupDocumentContainsTasksAndSessions() throws {
        let task = LumaTask(title: "Enviar formulario", area: .errands)
        let session = FocusSession(
            taskID: task.id,
            taskTitle: task.title,
            area: task.area,
            plannedMinutes: 25,
            actualMinutes: 20,
            startedAt: .now,
            energyPreference: .normal
        )
        let document = try BackupService.document(tasks: [task], sessions: [session])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LumaBackupPayload.self, from: document.data)

        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.tasks.first?.title, task.title)
        XCTAssertEqual(payload.sessions.first?.actualMinutes, 20)
    }
}
