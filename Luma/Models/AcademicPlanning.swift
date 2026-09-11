import Foundation
import SwiftData

enum AcademicActivityType: String, Codable, CaseIterable, Identifiable {
    case assignment
    case reading
    case laboratory
    case classMeeting
    case study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assignment: "Entrega"
        case .reading: "Lectura"
        case .laboratory: "Laboratorio"
        case .classMeeting: "Clase"
        case .study: "Estudio"
        }
    }

    var symbol: String {
        switch self {
        case .assignment: "doc.text.fill"
        case .reading: "book.fill"
        case .laboratory: "flask.fill"
        case .classMeeting: "person.3.fill"
        case .study: "brain.head.profile"
        }
    }
}

enum ExamImportance: String, Codable, CaseIterable, Identifiable {
    case normal
    case important
    case critical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .important: "Importante"
        case .critical: "Muy importante"
        }
    }

    var scoreBoost: Double {
        switch self {
        case .normal: 2
        case .important: 8
        case .critical: 14
        }
    }
}

enum ExamStudyStage: String, Codable, CaseIterable, Identifiable {
    case read
    case summarize
    case questions
    case review
    case finalReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "Leer"
        case .summarize: "Resumir"
        case .questions: "Hacer preguntas"
        case .review: "Repasar"
        case .finalReview: "Repaso final"
        }
    }

    var shortTitle: String {
        switch self {
        case .questions: "Preguntas"
        case .finalReview: "Final"
        default: title
        }
    }
}

enum PlanningMode: String, Codable, CaseIterable, Identifiable {
    case gentle
    case realistic
    case intense

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: "Suave"
        case .realistic: "Realista"
        case .intense: "Intenso"
        }
    }

    var taskLimit: Int {
        switch self {
        case .gentle: 2
        case .realistic, .intense: 3
        }
    }

    var timeMultiplier: Double {
        switch self {
        case .gentle: 0.75
        case .realistic: 1
        case .intense: 1.2
        }
    }
}

enum AcademicTaskSourceType: String, Codable {
    case routine
    case examStudy
    case rest
}

enum AcademicCaptureKind: String, Codable, CaseIterable, Identifiable {
    case subject
    case task
    case routine
    case exam
    case classMeeting
    case study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subject: "Materia"
        case .task: "Tarea"
        case .routine: "Rutina"
        case .exam: "Examen"
        case .classMeeting: "Clase"
        case .study: "Estudio"
        }
    }

    var symbol: String {
        switch self {
        case .subject: "books.vertical.fill"
        case .task: "checklist"
        case .routine: "arrow.triangle.2.circlepath"
        case .exam: "graduationcap.fill"
        case .classMeeting: "person.3.fill"
        case .study: "book.fill"
        }
    }
}

struct AcademicCaptureDraft: Identifiable, Equatable {
    var id = UUID()
    var originalText = ""
    var kind: AcademicCaptureKind = .task
    var title = ""
    var subjectID: UUID?
    var proposedSubjectName: String?
    var date: Date?
    var weekday: Int?
    var minuteOfDay: Int?
    var estimatedMinutes = 30
    var energy: EnergyLevel = .medium
    var importance: ExamImportance = .important
    var activityType: AcademicActivityType = .assignment
    var topicsRaw = ""
    var isRecurring = false
}

struct AcademicCaptureInterpretationResult {
    var drafts: [AcademicCaptureDraft]
    var notice: String?
}

enum AcademicCaptureMissingField: String, Codable, Equatable {
    case title
    case subject
    case subjectConfirmation
    case date
    case weekday
    case time
}

struct AcademicCaptureClarification: Equatable {
    var draftID: UUID
    var field: AcademicCaptureMissingField
    var question: String
}

struct AcademicCaptureContinuation {
    var originalRequest: String
    var draft: AcademicCaptureDraft
    var requestedField: AcademicCaptureMissingField
    var question: String
}

@Model
final class SubjectClassMeeting {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var weekday: Int
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int
    var location: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        subjectID: UUID,
        weekday: Int,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        location: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.subjectID = subjectID
        self.weekday = weekday
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.location = location
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class AcademicRoutine {
    @Attribute(.unique) var id: UUID
    var title: String
    var subjectID: UUID?
    var weekday: Int
    var minuteOfDay: Int?
    var activityTypeRaw: String
    var estimatedMinutes: Int
    var startDate: Date
    var endDate: Date?
    var isPaused: Bool
    var pauseDuringVacation: Bool
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        subjectID: UUID? = nil,
        weekday: Int,
        minuteOfDay: Int? = nil,
        activityType: AcademicActivityType = .assignment,
        estimatedMinutes: Int = 30,
        startDate: Date = .now,
        endDate: Date? = nil,
        isPaused: Bool = false,
        pauseDuringVacation: Bool = true,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.subjectID = subjectID
        self.weekday = weekday
        self.minuteOfDay = minuteOfDay
        activityTypeRaw = activityType.rawValue
        self.estimatedMinutes = estimatedMinutes
        self.startDate = startDate
        self.endDate = endDate
        self.isPaused = isPaused
        self.pauseDuringVacation = pauseDuringVacation
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var activityType: AcademicActivityType {
        get { AcademicActivityType(rawValue: activityTypeRaw) ?? .assignment }
        set { activityTypeRaw = newValue.rawValue }
    }
}

@Model
final class AcademicExam {
    @Attribute(.unique) var id: UUID
    var title: String
    var subjectID: UUID
    var date: Date
    var preparationStartDate: Date?
    var preparationEnabled: Bool?
    var academicWeight: Double?
    var topicsRaw: String
    var importanceRaw: String
    var preparationMinutes: Int
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        subjectID: UUID,
        date: Date,
        topicsRaw: String = "",
        importance: ExamImportance = .important,
        preparationMinutes: Int = 240,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.subjectID = subjectID
        self.date = date
        self.topicsRaw = topicsRaw
        importanceRaw = importance.rawValue
        self.preparationMinutes = preparationMinutes
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var shouldPrepare: Bool { preparationEnabled ?? true }
    var preparationStart: Date {
        preparationStartDate ?? Calendar.current.date(byAdding: .day, value: -14, to: date) ?? date
    }

    var topics: [String] {
        get {
            topicsRaw
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set { topicsRaw = newValue.joined(separator: "\n") }
    }

    var importance: ExamImportance {
        get { ExamImportance(rawValue: importanceRaw) ?? .important }
        set { importanceRaw = newValue.rawValue }
    }
}

@Model
final class DailyPlanningContext {
    @Attribute(.unique) var id: UUID
    var day: Date
    var energyRaw: String
    var availableMinutes: Int
    var planningModeRaw: String
    var restCounts: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        day: Date,
        energy: EnergyPreference = .normal,
        availableMinutes: Int = 120,
        planningMode: PlanningMode = .realistic,
        restCounts: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.day = Calendar.current.startOfDay(for: day)
        energyRaw = energy.rawValue
        self.availableMinutes = availableMinutes
        planningModeRaw = planningMode.rawValue
        self.restCounts = restCounts
        self.updatedAt = updatedAt
    }

    var energy: EnergyPreference {
        get { EnergyPreference(rawValue: energyRaw) ?? .normal }
        set { energyRaw = newValue.rawValue }
    }

    var planningMode: PlanningMode {
        get { PlanningMode(rawValue: planningModeRaw) ?? .realistic }
        set { planningModeRaw = newValue.rawValue }
    }
}
