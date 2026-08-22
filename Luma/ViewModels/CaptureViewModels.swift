import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class QuickCaptureViewModel {
    var draft = ParsedTaskDraft()

    func activeSubjects(from subjects: [AcademicSubject]) -> [AcademicSubject] {
        subjects.filter { !$0.isArchived }
    }

    func activeGradeItems(from items: [SubjectGradeItem]) -> [SubjectGradeItem] {
        items.filter { !$0.isArchived }
    }

    func assignmentIsValid(subjects: [AcademicSubject], gradeItems: [SubjectGradeItem]) -> Bool {
        guard draft.area == .university else { return true }
        guard let subjectID = draft.academicSubjectID else {
            return draft.subjectGradeItemID == nil && draft.grade == nil
        }
        guard activeSubjects(from: subjects).contains(where: { $0.id == subjectID }) else { return false }
        guard let itemID = draft.subjectGradeItemID else { return draft.grade == nil }
        return activeGradeItems(from: gradeItems).contains {
            $0.id == itemID && $0.subjectID == subjectID
        }
    }

    func canSave(subjects: [AcademicSubject], gradeItems: [SubjectGradeItem]) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assignmentIsValid(subjects: subjects, gradeItems: gradeItems)
            && draft.grade.map { (0 ... 10).contains($0) } != false
    }
}

@MainActor
@Observable
final class MenuBarCaptureViewModel {
    var input = ""
    var saved = false
}

@MainActor
@Observable
final class TaskEditorViewModel {
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
    var unlocksTaskID: UUID?
    var notes: String
    var isCompleted: Bool

    init(task: LumaTask) {
        title = task.title
        area = task.area
        deadline = task.deadline
        estimatedMinutes = task.estimatedMinutes
        energy = task.energy
        impact = task.impact
        academicWeight = task.academicWeight
        academicSubjectID = task.academicSubjectID
        subjectGradeItemID = task.subjectGradeItemID
        grade = task.grade
        unlocksTaskID = task.unlocksTaskID
        notes = task.notes
        isCompleted = task.isCompleted
    }

    func availableSubjects(from subjects: [AcademicSubject]) -> [AcademicSubject] {
        subjects.filter { !$0.isArchived || $0.id == academicSubjectID }
    }

    func availableGradeItems(from items: [SubjectGradeItem]) -> [SubjectGradeItem] {
        items.filter { !$0.isArchived || $0.id == subjectGradeItemID }
    }

    func assignmentIsValid(subjects: [AcademicSubject], gradeItems: [SubjectGradeItem]) -> Bool {
        guard area == .university else { return true }
        guard let academicSubjectID else { return subjectGradeItemID == nil && grade == nil }
        guard availableSubjects(from: subjects).contains(where: { $0.id == academicSubjectID }) else { return false }
        guard let subjectGradeItemID else { return grade == nil }
        return availableGradeItems(from: gradeItems).contains {
            $0.id == subjectGradeItemID && $0.subjectID == academicSubjectID
        }
    }

    func canSave(subjects: [AcademicSubject], gradeItems: [SubjectGradeItem]) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assignmentIsValid(subjects: subjects, gradeItems: gradeItems)
            && grade.map { (0 ... 10).contains($0) } != false
    }

    func apply(to task: LumaTask) {
        task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.area = area
        task.deadline = deadline
        task.estimatedMinutes = estimatedMinutes
        task.energy = energy
        task.impact = impact
        task.academicWeight = area == .university ? academicWeight : nil
        task.academicSubjectID = area == .university ? academicSubjectID : nil
        task.subjectGradeItemID = area == .university ? subjectGradeItemID : nil
        task.grade = area == .university ? grade : nil
        task.unlocksTaskID = unlocksTaskID
        task.unlocksAnotherTask = unlocksTaskID != nil
        task.notes = notes
        if isCompleted, !task.isCompleted {
            task.markCompleted()
        } else if !isCompleted, task.isCompleted {
            task.restore()
        }
        task.touch()
    }
}
