import Foundation
import SwiftData

@Model
final class AcademicSubject {
    @Attribute(.unique) var id: UUID
    var name: String
    var targetGrade: Double?
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        targetGrade: Double? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.targetGrade = targetGrade
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}

@Model
final class SubjectGradeItem {
    @Attribute(.unique) var id: UUID
    var subjectID: UUID
    var title: String
    var weightPercent: Double
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        subjectID: UUID,
        title: String,
        weightPercent: Double,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isArchived: Bool = false
    ) {
        self.id = id
        self.subjectID = subjectID
        self.title = title
        self.weightPercent = weightPercent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
}
