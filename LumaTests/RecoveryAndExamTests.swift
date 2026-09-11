@testable import Luma
import SwiftData
import XCTest

@MainActor
final class RecoveryAndExamTests: XCTestCase {
    private func store() throws -> ModelContainer {
        let schema = Schema([LumaTask.self, FocusSession.self, StudyGuide.self, AcademicSubject.self, SubjectGradeItem.self,
            SubjectClassMeeting.self, AcademicRoutine.self, AcademicExam.self, DailyPlanningContext.self,
            LumaProfile.self, LumaChatRecord.self, LumaReplanRecord.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    func testCompleteBackupRestoresIntoEmptyStoreAndKeepsPreparationMetadata() throws {
        let source = try store()
        let context = source.mainContext
        let subject = AcademicSubject(name: "Historia", targetGrade: 8, colorHex: "#AABBCC", syllabusRaw: "Unidad 1\nUnidad 2")
        let exam = AcademicExam(title: "Parcial", subjectID: subject.id, date: .now.addingTimeInterval(14 * 86400))
        exam.preparationStartDate = .now.addingTimeInterval(3 * 86400)
        exam.preparationEnabled = true; exam.academicWeight = 30
        let task = LumaTask(title: "Tema 1", area: .university, dueDate: exam.date, academicSubjectID: subject.id, focusedMinutes: 20, sourceTypeRaw: "examStudy", sourceID: exam.id)
        task.planningDetails = TaskPlanningDetails(startDate: exam.preparationStartDate, studyOrder: 1)
        let meeting = SubjectClassMeeting(subjectID: subject.id, weekday: 2, startMinuteOfDay: 600, endMinuteOfDay: 660)
        let routine = AcademicRoutine(title: "Leer", subjectID: subject.id, weekday: 3)
        let profile = LumaProfile(selectedAreas: [.university, .hobbies])
        let daily = DailyPlanningContext(day: .now, availableMinutes: 105)
        context.insert(subject); context.insert(exam); context.insert(task); context.insert(meeting)
        context.insert(routine); context.insert(profile); context.insert(daily)
        try context.save()
        let document = try BackupService.document(tasks: [task], sessions: [], subjects: [subject], classMeetings: [meeting], routines: [routine], exams: [exam], dailyContexts: [daily], profiles: [profile])
        let preview = try BackupService.preview(data: document.data)
        XCTAssertEqual(preview.version, 2)
        let destination = try store()
        try BackupService.restore(data: document.data, existingTasks: [], existingSessions: [], context: destination.mainContext)
        let recovered = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<LumaTask>()).first)
        XCTAssertEqual(recovered.focusedMinutes, 20)
        XCTAssertEqual(recovered.sourceID, exam.id)
        XCTAssertEqual(recovered.planningDetails.studyOrder, 1)
        let recoveredExam = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<AcademicExam>()).first)
        XCTAssertEqual(recoveredExam.academicWeight, 30)
        XCTAssertNotNil(recoveredExam.preparationStartDate)
        let recoveredSubject = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<AcademicSubject>()).first)
        XCTAssertEqual(recoveredSubject.targetGrade, 8)
        XCTAssertEqual(recoveredSubject.colorHex, "#AABBCC")
        XCTAssertEqual(recoveredSubject.syllabusRaw, subject.syllabusRaw)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<SubjectClassMeeting>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<AcademicRoutine>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<LumaProfile>()), 1)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<DailyPlanningContext>()), 1)
    }

    func testPreferencesBackupExcludesCredentialsAndRestoresLedger() throws {
        let sourceName = "LumaTests.backup.source.\(UUID())", destinationName = "LumaTests.backup.dest.\(UUID())"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceName)), destination = try XCTUnwrap(UserDefaults(suiteName: destinationName))
        defer { source.removePersistentDomain(forName: sourceName); destination.removePersistentDomain(forName: destinationName) }
        source.set("private", forKey: "supabase.auth.token")
        let state = AppState(defaults: source)
        state.ensureDailyTimeBudget(availableMinutes: 120)
        state.recordTimeSpent(eventID: UUID(), minutes: 45)
        state.setRemainingAvailableMinutes(105)
        let preferences = BackupService.preferences(defaults: source)
        XCTAssertNil(preferences["supabase.auth.token"])
        try BackupService.restorePreferences(preferences, defaults: destination)
        XCTAssertEqual(AppState(defaults: destination).remainingAvailableMinutes(), 105)
        XCTAssertNil(destination.string(forKey: "supabase.auth.token"))
    }

    func testCorruptBackupCannotPartiallyInsertTasks() throws {
        let task = LumaTask(title: "Valid", area: .home)
        let doc = try BackupService.document(tasks: [task], sessions: [])
        var payload = try BackupService.preview(data: doc.data)
        payload.tasks.append(payload.tasks[0])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let destination = try store()
        XCTAssertThrowsError(try BackupService.restore(data: encoder.encode(payload), existingTasks: [], existingSessions: [], context: destination.mainContext))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<LumaTask>()), 0)
    }

    func testEditingExamDatePreservesIDsAndPartialStudyProgress() throws {
        let container = try store(), context = container.mainContext
        let exam = AcademicExam(title: "Parcial", subjectID: UUID(), date: .now.addingTimeInterval(14 * 86400))
        let topic = StudyTopic(title: "Unidad 1", summary: "", keyPoints: [], sourcePages: [], importance: 2, suggestedMinutes: 60, taskID: nil)
        context.insert(exam)
        let service = AcademicPlanningService()
        service.materializeGeneratedExamStudy(exam: exam, topics: [topic], sourceFileName: "", tasks: [], in: context)
        try context.save()
        let original = try context.fetch(FetchDescriptor<LumaTask>())
        let study = try XCTUnwrap(original.first { $0.title.contains("Unidad 1") })
        study.recordFocusSession(minutes: 25)
        let ids = Set(original.map(\.id))
        exam.title = "Parcial actualizado"; exam.date = exam.date.addingTimeInterval(2 * 86400)
        // A newly parsed topic has a fresh source UUID but is still the same unit.
        let edited = StudyTopic(title: "Unidad 1", summary: "", keyPoints: [], sourcePages: [], importance: 2, suggestedMinutes: 60, taskID: nil)
        service.materializeGeneratedExamStudy(exam: exam, topics: [edited], sourceFileName: "", tasks: original, in: context)
        try context.save()
        let result = try context.fetch(FetchDescriptor<LumaTask>())
        XCTAssertEqual(Set(result.map(\.id)), ids)
        XCTAssertEqual(study.focusedMinutes, 25)
        XCTAssertEqual(study.dueDate, exam.date)
        XCTAssertNil(study.deadline, "Preparation must not invent a 19:00 appointment")
    }

    func testExamCanBePreparedWithoutInventingTopics() throws {
        let container = try store()
        let exam = AcademicExam(title: "Historia", subjectID: UUID(), date: .now.addingTimeInterval(14 * 86400))
        container.mainContext.insert(exam)
        AcademicPlanningService().materialize(routines: [], exams: [exam], tasks: [], dailyContext: nil, in: container.mainContext)
        let tasks = try container.mainContext.fetch(FetchDescriptor<LumaTask>())
        XCTAssertFalse(tasks.isEmpty)
        XCTAssertTrue(tasks.allSatisfy { $0.notes.contains("sin temario") && $0.planningDetails.studyOrder != nil })
    }

    func testReminderCapSurvivesReplanningAndCountsSnoozes() {
        let now = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
        var budget = ReminderBudget()
        XCTAssertTrue(budget.reserve(id: "one", date: now.addingTimeInterval(60), now: now))
        budget.cancelPending(now: now.addingTimeInterval(120))
        XCTAssertTrue(budget.reserve(id: "two", date: now.addingTimeInterval(180), now: now.addingTimeInterval(120)))
        XCTAssertTrue(budget.reserve(id: "snooze", date: now.addingTimeInterval(900), now: now))
        XCTAssertFalse(budget.reserve(id: "four", date: now.addingTimeInterval(1800), now: now))
    }

    func testAssistantFindsNamedTaskBeyondFirstForty() {
        var tasks = (0..<60).map { LumaTask(title: "Lectura \($0)", area: .university) }
        let wanted = LumaTask(title: "Enviar cotización diseño", area: .sideHustle)
        tasks.append(wanted)
        let result = LumaAssistantContextBuilder.relevantTasks(tasks, question: "Quiero hacer primero enviar cotización diseño", recommendations: [])
        XCTAssertEqual(result.first?.id, wanted.id)
    }
    func testDuplicateExamBackupIsRejectedBeforeInsertingAnyTask() throws {
        let exam = AcademicExam(title: "Parcial", subjectID: UUID(), date: .now)
        let doc = try BackupService.document(tasks: [LumaTask(title: "Pendiente", area: .home)], sessions: [], exams: [exam])
        var payload = try BackupService.preview(data: doc.data)
        let duplicate = try XCTUnwrap(payload.exams?.first)
        payload.exams?.append(duplicate)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let destination = try store()
        XCTAssertThrowsError(try BackupService.restore(data: encoder.encode(payload), existingTasks: [], existingSessions: [], context: destination.mainContext))
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<LumaTask>()), 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<AcademicExam>()), 0)
    }

}
