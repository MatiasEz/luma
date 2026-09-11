@testable import Luma
import XCTest

final class NaturalLanguageTaskParserTests: XCTestCase {
    func testAcademicCaptureUnderstandsTypoInWeeklyRoutine() {
        let draft = AcademicCaptureParser().parse(
            "Crea una tarea para todos klos domingos que sea dormir",
            subjects: []
        )

        XCTAssertEqual(draft.kind, .routine)
        XCTAssertEqual(draft.title, "Dormir")
        XCTAssertEqual(draft.weekday, 1)
        XCTAssertTrue(draft.isRecurring)
    }

    func testAcademicCaptureUnderstandsColloquialDateAndWordTime() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
        let draft = AcademicCaptureParser(calendar: calendar).parse(
            "Agendame llamar al veterinario mañana a las ocho de la noche",
            subjects: [],
            now: now
        )

        XCTAssertEqual(draft.title, "Llamar al veterinario")
        XCTAssertEqual(draft.minuteOfDay, 20 * 60)
        XCTAssertEqual(draft.date.map { calendar.component(.day, from: $0) }, 31)
    }

    func testAcademicCaptureUnderstandsPluralWeekdayAndNaturalDuration() {
        let draft = AcademicCaptureParser().parse(
            "Los martes repasar anatomía durante una hora y media",
            subjects: []
        )

        XCTAssertEqual(draft.kind, .routine)
        XCTAssertEqual(draft.title, "Repasar anatomía")
        XCTAssertEqual(draft.weekday, 3)
        XCTAssertEqual(draft.estimatedMinutes, 90)
    }

    func testAcademicCaptureUnderstandsNumericSpanishDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))
        let draft = AcademicCaptureParser(calendar: calendar).parse(
            "El 12/9 rindo Parasitología sobre helmintos y protozoarios",
            subjects: [],
            now: now
        )

        XCTAssertEqual(draft.kind, .exam)
        XCTAssertEqual(draft.date.map { calendar.component(.day, from: $0) }, 12)
        XCTAssertEqual(draft.date.map { calendar.component(.month, from: $0) }, 9)
        XCTAssertEqual(draft.topicsRaw, "helmintos, protozoarios")
    }

    func testParsesAcademicTask() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 18)))

        let draft = NaturalLanguageTaskParser(calendar: calendar).parse(
            "Examen de historia el viernes, vale 30% y necesito 2 horas",
            now: now
        )

        XCTAssertEqual(draft.area, .university)
        XCTAssertEqual(draft.impact, .grade)
        XCTAssertEqual(draft.academicWeight, 30)
        XCTAssertEqual(draft.estimatedMinutes, 120)
        XCTAssertEqual(draft.energy, .high)
        XCTAssertNotNil(draft.deadline)
    }

    func testParsesFreelanceTask() {
        let draft = NaturalLanguageTaskParser().parse("Enviar cotización freelance mañana, 25 min")

        XCTAssertEqual(draft.area, .sideHustle)
        XCTAssertEqual(draft.impact, .money)
        XCTAssertEqual(draft.estimatedMinutes, 25)
        XCTAssertNotNil(draft.deadline)
    }

    func testExtractsJSONAfterThinkingBlock() throws {
        let response = """
        <think>contenido que no debe mostrarse</think>
        ```json
        {"title":"Leer capítulo 4"}
        ```
        """

        let data = try XCTUnwrap(JSONExtractor.objectData(from: response))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["title"], "Leer capítulo 4")
    }

    func testExtractsJSONFromTruncatedThinkingResponse() throws {
        let response = """
        <think>Voy a resolverlo. La salida será {"title":"Enviar factura","area":"sideHustle"}</think>
        """

        let data = try XCTUnwrap(JSONExtractor.objectData(from: response))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["area"], "sideHustle")
    }

    func testExplicitSignalsOverrideIncorrectSmallModelGuess() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 18)))
        let explicit = NaturalLanguageTaskParser(calendar: calendar).parse(
            "Examen de historia el viernes, vale 30% y necesito 2 horas",
            now: now
        )
        let incorrectAI = ParsedTaskDraft(
            title: "Examination",
            area: .home,
            estimatedMinutes: 30,
            energy: .low,
            impact: .money
        )

        let merged = ParsedTaskValidator.merge(ai: incorrectAI, explicit: explicit)

        XCTAssertEqual(merged.area, .university)
        XCTAssertEqual(merged.impact, .grade)
        XCTAssertEqual(merged.energy, .high)
        XCTAssertEqual(merged.estimatedMinutes, 120)
        XCTAssertEqual(merged.academicWeight, 30)
        XCTAssertNotNil(merged.deadline)
    }

    func testExplicitAcademicTaskDoesNotNeedAI() {
        let parser = NaturalLanguageTaskParser()
        let draft = parser.parse("Examen de historia el viernes, vale 30% y necesito 2 horas")
        XCTAssertFalse(parser.shouldUseAI(for: draft))
    }

    func testAmbiguousTaskCanAskAIForHelp() {
        let parser = NaturalLanguageTaskParser()
        let draft = parser.parse("Preparar todo para el proyecto")
        XCTAssertTrue(parser.shouldUseAI(for: draft))
    }
}
