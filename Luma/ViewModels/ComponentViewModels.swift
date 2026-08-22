import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class InboxTaskRowViewModel {
    var isGradeEntryExpanded = false
    var grade: Double?

    func cancelGradeEntry() {
        grade = nil
        isGradeEntryExpanded = false
    }

    func submittedGrade() -> Double? {
        guard let grade, (0 ... 10).contains(grade) else { return nil }
        cancelGradeEntry()
        return grade
    }
}

@MainActor
@Observable
final class DraggableAgendaRowViewModel {
    var dragOffset: CGFloat = 0

    func finishDrag(translation: CGFloat, currentStart: Int) -> Int? {
        let stepCount = Int((translation / 26).rounded())
        dragOffset = 0
        guard stepCount != 0 else { return nil }
        return currentStart + stepCount * 15
    }
}

@MainActor
@Observable
final class PriorityCardViewModel {
    var editingTask = false
}

@MainActor
@Observable
final class SubjectGradeDetailViewModel {
    var simulatorPresented = false
    var quickGradeEntryPresented = false

    func summary(items: [SubjectGradeItem], tasks: [LumaTask]) -> SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(items: items, tasks: tasks)
    }

    func gradeEntryTasks(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { $0.subjectGradeItemID != nil && ($0.isCompleted || $0.grade != nil) }
    }
}

@MainActor
@Observable
final class QuickGradeEntryViewModel {
    var selectedSubjectID: UUID?
    var gradeTexts: [UUID: String]

    init(subjects: [AcademicSubject], tasks: [LumaTask]) {
        selectedSubjectID = subjects.count == 1 ? subjects.first?.id : nil
        gradeTexts = Dictionary(uniqueKeysWithValues: tasks.map { task in
            let text = task.grade?.formatted(.number.precision(.fractionLength(0 ... 2))) ?? ""
            return (task.id, text)
        })
    }

    func filteredSubjects(_ subjects: [AcademicSubject], tasks: [LumaTask]) -> [AcademicSubject] {
        subjects.filter { subject in
            (selectedSubjectID == nil || selectedSubjectID == subject.id)
                && tasks.contains { $0.academicSubjectID == subject.id }
        }
    }

    func parsedGrade(for task: LumaTask) -> Double? {
        let text = (gradeTexts[task.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        return Double(text)
    }

    func inputIsValid(for task: LumaTask) -> Bool {
        let text = (gradeTexts[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        guard let grade = parsedGrade(for: task) else { return false }
        return (0 ... 10).contains(grade)
    }

    func gradeChanged(for task: LumaTask) -> Bool {
        guard inputIsValid(for: task) else { return false }
        switch (task.grade, parsedGrade(for: task)) {
        case (nil, nil): return false
        case let (old?, new?): return abs(old - new) > 0.0001
        default: return true
        }
    }

    func changedTasks(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter(gradeChanged)
    }

    func allInputsAreValid(tasks: [LumaTask]) -> Bool {
        tasks.allSatisfy(inputIsValid)
    }

    func applyGrades(to tasks: [LumaTask]) {
        for task in changedTasks(from: tasks) {
            task.grade = parsedGrade(for: task)
            task.touch()
        }
    }
}

@MainActor
@Observable
final class GradeSimulatorViewModel {
    var simulatedGrades: [UUID: Double] = [:]

    func pendingTasks(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter {
            $0.academicEvaluationStatus == .upcomingEvaluation
                || $0.academicEvaluationStatus == .awaitingGrade
        }
    }

    func summary(
        items: [SubjectGradeItem],
        tasks: [LumaTask],
        includeSimulation: Bool
    ) -> SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(
            items: items,
            tasks: tasks,
            simulatedGrades: includeSimulation ? simulatedGrades : [:]
        )
    }

    func allSimulated(tasks: [LumaTask]) -> Bool {
        let pending = pendingTasks(from: tasks)
        return !pending.isEmpty && pending.allSatisfy { simulatedGrades[$0.id] != nil }
    }

    var valuesAreValid: Bool {
        simulatedGrades.values.allSatisfy { (0 ... 10).contains($0) }
    }

    func useRequiredGrade(_ grade: Double, tasks: [LumaTask]) {
        for task in pendingTasks(from: tasks) { simulatedGrades[task.id] = grade }
    }
}

@MainActor
@Observable
final class SubjectEditorViewModel {
    var name: String
    var targetGrade: Double?
    var drafts: [GradeItemDraft]

    init(subject: AcademicSubject?, existingItems: [SubjectGradeItem]) {
        name = subject?.name ?? ""
        targetGrade = subject?.targetGrade
        drafts = existingItems.isEmpty && subject == nil
            ? [GradeItemDraft()]
            : existingItems.map(GradeItemDraft.init)
    }

    var parsedItems: [(draft: GradeItemDraft, weight: Double)]? {
        var result: [(GradeItemDraft, Double)] = []
        for draft in drafts {
            let normalized = draft.weightText.replacingOccurrences(of: ",", with: ".")
            guard !draft.trimmedTitle.isEmpty,
                  let weight = Double(normalized),
                  weight > 0,
                  weight <= 100
            else { return nil }
            result.append((draft, weight))
        }
        return result
    }

    var total: Double {
        parsedItems?.reduce(0) { $0 + $1.weight } ?? 0
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasDuplicateName(subject: AcademicSubject?, allSubjects: [AcademicSubject]) -> Bool {
        allSubjects.contains {
            !$0.isArchived
                && $0.id != subject?.id
                && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    func canSave(subject: AcademicSubject?, allSubjects: [AcademicSubject]) -> Bool {
        !trimmedName.isEmpty
            && !hasDuplicateName(subject: subject, allSubjects: allSubjects)
            && !drafts.isEmpty
            && parsedItems != nil
            && total <= 100
            && targetGrade.map { (0 ... 10).contains($0) } != false
    }
}
