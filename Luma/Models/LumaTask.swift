import Foundation
import SwiftData

enum AcademicEvaluationStatus: String, CaseIterable, Identifiable {
    case notEvaluable
    case upcomingEvaluation
    case awaitingGrade
    case graded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notEvaluable: "No evaluable"
        case .upcomingEvaluation: "Próxima evaluación"
        case .awaitingGrade: "Esperando nota"
        case .graded: "Calificada"
        }
    }

    var symbol: String {
        switch self {
        case .notEvaluable: "book.closed"
        case .upcomingEvaluation: "calendar.badge.clock"
        case .awaitingGrade: "clock.badge.questionmark"
        case .graded: "checkmark.seal.fill"
        }
    }
}

@Model
final class LumaTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var areaRaw: String
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
    var completedAt: Date?
    var postponementCount: Int
    var unlocksAnotherTask: Bool
    var unlocksTaskID: UUID?
    var notes: String
    var focusedMinutes: Int = 0
    var focusSessionCount: Int = 0
    var lastFocusedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        area: LifeArea,
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
        completedAt: Date? = nil,
        postponementCount: Int = 0,
        unlocksAnotherTask: Bool = false,
        unlocksTaskID: UUID? = nil,
        notes: String = "",
        focusedMinutes: Int = 0,
        focusSessionCount: Int = 0,
        lastFocusedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        areaRaw = area.rawValue
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
        self.completedAt = completedAt
        self.postponementCount = postponementCount
        self.unlocksAnotherTask = unlocksAnotherTask
        self.unlocksTaskID = unlocksTaskID
        self.notes = notes
        self.focusedMinutes = focusedMinutes
        self.focusSessionCount = focusSessionCount
        self.lastFocusedAt = lastFocusedAt
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

    func markCompleted() {
        status = .completed
        completedAt = .now
    }

    func restore() {
        status = .pending
        completedAt = nil
    }

    func recordFocusSession(minutes: Int, at date: Date = .now) {
        guard minutes > 0 else { return }
        focusedMinutes += minutes
        focusSessionCount += 1
        lastFocusedAt = date
    }
}

struct ParsedTaskDraft: Equatable {
    var title: String
    var area: LifeArea
    var deadline: Date?
    var estimatedMinutes: Int
    var energy: EnergyLevel
    var impact: ImpactType
    var academicWeight: Double?
    var academicSubjectID: UUID?
    var subjectGradeItemID: UUID?
    var grade: Double?
    var unlocksAnotherTask: Bool
    var unlocksTaskID: UUID?
    var notes: String

    init(
        title: String = "",
        area: LifeArea = .errands,
        deadline: Date? = nil,
        estimatedMinutes: Int = 30,
        energy: EnergyLevel = .medium,
        impact: ImpactType = .general,
        academicWeight: Double? = nil,
        academicSubjectID: UUID? = nil,
        subjectGradeItemID: UUID? = nil,
        grade: Double? = nil,
        unlocksAnotherTask: Bool = false,
        unlocksTaskID: UUID? = nil,
        notes: String = ""
    ) {
        self.title = title
        self.area = area
        self.deadline = deadline
        self.estimatedMinutes = estimatedMinutes
        self.energy = energy
        self.impact = impact
        self.academicWeight = academicWeight
        self.academicSubjectID = academicSubjectID
        self.subjectGradeItemID = subjectGradeItemID
        self.grade = grade
        self.unlocksAnotherTask = unlocksAnotherTask
        self.unlocksTaskID = unlocksTaskID
        self.notes = notes
    }
}
