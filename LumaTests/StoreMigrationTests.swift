@testable import Luma
import SwiftData
import XCTest

// Frozen 0.7.3 entity: protects real upgrades rather than only testing new stores.
private enum LegacyTaskSchema {
@Model
final class LumaTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var areaRaw: String
    /// The real delivery date. The planner aims to finish before this day.
    var dueDate: Date?
    /// The concrete start time chosen for the calendar.
    var deadline: Date?
    var estimatedMinutes: Int
    var energyRaw: String
    var impactRaw: String
    var academicWeight: Double?
    var academicSubjectID: UUID?
    var subjectGradeItemID: UUID?
    var grade: Double?
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date = Date.now
    var completedAt: Date?
    var postponementCount: Int
    var unlocksAnotherTask: Bool
    var unlocksTaskID: UUID?
    var notes: String
    var focusedMinutes: Int = 0
    var focusSessionCount: Int = 0
    var lastFocusedAt: Date?
    var sourceTypeRaw: String?
    var sourceID: UUID?
    var sourceOccurrenceDate: Date?
    var studyStageRaw: String?

    init(
        id: UUID = UUID(),
        title: String,
        area: LifeArea,
        dueDate: Date? = nil,
        deadline: Date? = nil,
        estimatedMinutes: Int = 30,
        energy: EnergyLevel = .medium,
        impact: ImpactType = .general,
        academicWeight: Double? = nil,
        academicSubjectID: UUID? = nil,
        subjectGradeItemID: UUID? = nil,
        grade: Double? = nil,
        status: TaskStatus = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        completedAt: Date? = nil,
        postponementCount: Int = 0,
        unlocksAnotherTask: Bool = false,
        unlocksTaskID: UUID? = nil,
        notes: String = "",
        focusedMinutes: Int = 0,
        focusSessionCount: Int = 0,
        lastFocusedAt: Date? = nil,
        sourceTypeRaw: String? = nil,
        sourceID: UUID? = nil,
        sourceOccurrenceDate: Date? = nil,
        studyStageRaw: String? = nil
    ) {
        self.id = id
        self.title = title
        areaRaw = area.rawValue
        self.dueDate = dueDate
        self.deadline = deadline
        self.estimatedMinutes = estimatedMinutes
        energyRaw = energy.rawValue
        impactRaw = impact.rawValue
        self.academicWeight = academicWeight
        self.academicSubjectID = academicSubjectID
        self.subjectGradeItemID = subjectGradeItemID
        self.grade = grade
        statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.postponementCount = postponementCount
        self.unlocksAnotherTask = unlocksAnotherTask
        self.unlocksTaskID = unlocksTaskID
        self.notes = notes
        self.focusedMinutes = focusedMinutes
        self.focusSessionCount = focusSessionCount
        self.lastFocusedAt = lastFocusedAt
        self.sourceTypeRaw = sourceTypeRaw
        self.sourceID = sourceID
        self.sourceOccurrenceDate = sourceOccurrenceDate
        self.studyStageRaw = studyStageRaw
    }

    var area: LifeArea {
        get { LifeArea(rawValue: areaRaw) ?? .errands }
        set { areaRaw = newValue.rawValue }
    }

    var energy: EnergyLevel {
        get { EnergyLevel(rawValue: energyRaw) ?? .medium }
        set { energyRaw = newValue.rawValue }
    }

    var impact: ImpactType {
        get { ImpactType(rawValue: impactRaw) ?? .general }
        set { impactRaw = newValue.rawValue }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var isCompleted: Bool { status == .completed }

    var academicSourceType: AcademicTaskSourceType? {
        get { sourceTypeRaw.flatMap(AcademicTaskSourceType.init(rawValue:)) }
        set { sourceTypeRaw = newValue?.rawValue }
    }

    var studyStage: ExamStudyStage? {
        get { studyStageRaw.flatMap(ExamStudyStage.init(rawValue:)) }
        set { studyStageRaw = newValue?.rawValue }
    }

    var academicEvaluationStatus: AcademicEvaluationStatus? {
        guard academicSubjectID != nil else { return nil }
        guard subjectGradeItemID != nil else { return .notEvaluable }
        guard grade == nil else { return .graded }
        return isCompleted ? .awaitingGrade : .upcomingEvaluation
    }

    var remainingEstimatedMinutes: Int {
        guard !isCompleted else { return 0 }
        return max(10, estimatedMinutes - focusedMinutes)
    }

    var calendarDate: Date? { deadline }

    /// Last day on which Luma should plan work. A delivery is prepared at least
    /// one day earlier, except when the task was created on its delivery day.
    func planningTargetDate(calendar: Calendar = .current) -> Date? {
        if let dueDate {
            let dueDay = calendar.startOfDay(for: dueDate)
            let createdDay = calendar.startOfDay(for: createdAt)
            guard dueDay > createdDay else { return dueDay }
            return calendar.date(byAdding: .day, value: -1, to: dueDay)
        }
        return deadline.map { calendar.startOfDay(for: $0) }
    }

    func markCompleted() {
        status = .completed
        completedAt = .now
        touch()
    }

    func restore() {
        status = .pending
        completedAt = nil
        touch()
    }

    func recordFocusSession(minutes: Int, at date: Date = .now) {
        guard minutes > 0 else { return }
        focusedMinutes += minutes
        focusSessionCount += 1
        lastFocusedAt = date
        touch(at: date)
    }

    func touch(at date: Date = .now) {
        updatedAt = date
    }
}

}

@MainActor
final class StoreMigrationTests: XCTestCase {
    private func createLegacyStore(at url: URL, id: UUID) throws {
        let schema = Schema([LegacyTaskSchema.LumaTask.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let task = LegacyTaskSchema.LumaTask(id: id, title: "Entrega conservada", area: .university,
            dueDate: .now.addingTimeInterval(86400), estimatedMinutes: 180, academicWeight: 30, focusedMinutes: 45)
        container.mainContext.insert(task)
        try container.mainContext.save()
    }

    func testOpening073StorePreservesTasksAndInitializesOptionalMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumaMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store"), id = UUID()
        try createLegacyStore(at: url, id: id)
        let schema = Schema([LumaTask.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let task = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LumaTask>()).first)
        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.title, "Entrega conservada")
        XCTAssertEqual(task.focusedMinutes, 45)
        XCTAssertEqual(task.academicWeight, 30)
        XCTAssertNil(task.planningDetailsRaw)
    }
}
