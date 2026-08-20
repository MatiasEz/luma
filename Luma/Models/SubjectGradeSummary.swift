import Foundation

struct SubjectGradeCategorySummary: Identifiable {
    let id: UUID
    let title: String
    let weightPercent: Double
    let assignedTaskCount: Int
    let gradedTaskCount: Int
    let pendingGradeTaskCount: Int
    let gradeSum: Double
    let averageGrade: Double?
    let weightedContribution: Double
}

struct SubjectGradeSummary {
    let categories: [SubjectGradeCategorySummary]
    let nonEvaluableTaskCount: Int

    var configuredWeight: Double {
        categories.reduce(0) { $0 + $1.weightPercent }
    }

    var gradedWeight: Double {
        categories
            .filter { $0.averageGrade != nil }
            .reduce(0) { $0 + $1.weightPercent }
    }

    var weightedContribution: Double {
        categories.reduce(0) { $0 + $1.weightedContribution }
    }

    var currentGrade: Double? {
        guard gradedWeight > 0 else { return nil }
        return weightedContribution * 100 / gradedWeight
    }

    var projectedFinalGrade: Double? {
        guard abs(configuredWeight - 100) < 0.001 else { return nil }
        return currentGrade
    }

    var finalGrade: Double? {
        guard abs(configuredWeight - 100) < 0.001,
              !categories.contains(where: { $0.assignedTaskCount == 0 }),
              pendingGradeTaskCount == 0
        else { return nil }
        return weightedContribution
    }

    var gradedTaskCount: Int {
        categories.reduce(0) { $0 + $1.gradedTaskCount }
    }

    var pendingGradeTaskCount: Int {
        categories.reduce(0) { $0 + $1.pendingGradeTaskCount }
    }

    var ungradedWeight: Double {
        max(0, 100 - gradedWeight)
    }

    var configuredWithoutGradesWeight: Double {
        max(0, configuredWeight - gradedWeight)
    }

    var unconfiguredWeight: Double {
        max(0, 100 - configuredWeight)
    }

    var hasUnassignedCategories: Bool {
        categories.contains { $0.assignedTaskCount == 0 }
    }

    func requiredAverage(for targetGrade: Double) -> Double? {
        guard (0 ... 10).contains(targetGrade),
              abs(configuredWeight - 100) < 0.001,
              pendingGradeTaskCount > 0,
              !hasUnassignedCategories
        else { return nil }

        let fixedContribution = categories.reduce(0.0) { result, category in
            guard category.assignedTaskCount > 0 else { return result }
            return result
                + category.weightPercent / 100
                * category.gradeSum / Double(category.assignedTaskCount)
        }
        let pendingCoefficient = categories.reduce(0.0) { result, category in
            guard category.assignedTaskCount > 0 else { return result }
            return result
                + category.weightPercent / 100
                * Double(category.pendingGradeTaskCount) / Double(category.assignedTaskCount)
        }
        guard pendingCoefficient > 0 else { return nil }
        return (targetGrade - fixedContribution) / pendingCoefficient
    }
}

enum SubjectGradeCalculator {
    static func makeSummary(
        items: [SubjectGradeItem],
        tasks: [LumaTask],
        simulatedGrades: [UUID: Double] = [:]
    ) -> SubjectGradeSummary {
        let categories = items.map { item in
            let assignedTasks = tasks.filter { $0.subjectGradeItemID == item.id }
            let grades = assignedTasks.compactMap { task -> Double? in
                let candidate = simulatedGrades[task.id] ?? task.grade
                guard let grade = candidate, (0 ... 10).contains(grade) else { return nil }
                return grade
            }
            let pendingGradeTaskCount = assignedTasks.count - grades.count
            let average = grades.isEmpty
                ? nil
                : grades.reduce(0, +) / Double(grades.count)
            return SubjectGradeCategorySummary(
                id: item.id,
                title: item.title,
                weightPercent: item.weightPercent,
                assignedTaskCount: assignedTasks.count,
                gradedTaskCount: grades.count,
                pendingGradeTaskCount: pendingGradeTaskCount,
                gradeSum: grades.reduce(0, +),
                averageGrade: average,
                weightedContribution: (average ?? 0) * item.weightPercent / 100
            )
        }
        return SubjectGradeSummary(
            categories: categories,
            nonEvaluableTaskCount: tasks.filter { $0.academicEvaluationStatus == .notEvaluable }.count
        )
    }
}

struct AcademicPriorityContext {
    let subjectName: String
    let targetGrade: Double
    let currentGrade: Double?
    let requiredAverage: Double?
    let categoryWeight: Double?

    var scoreBonus: Double {
        if let currentGrade, currentGrade >= targetGrade { return 0 }

        var bonus = currentGrade.map { min(14, 5 + max(0, targetGrade - $0) * 4) } ?? 7
        if let categoryWeight {
            bonus += min(12, categoryWeight * 0.24)
        }
        if let requiredAverage, requiredAverage > targetGrade {
            bonus += min(6, (requiredAverage - targetGrade) * 2)
        }
        return min(28, bonus)
    }

    var reason: String? {
        guard scoreBonus > 0 else { return nil }
        if let requiredAverage, requiredAverage > 10 {
            return "es clave para recuperar \(subjectName)"
        }
        if let categoryWeight, categoryWeight >= 20 {
            return "pesa \(categoryWeight.formatted(.number.precision(.fractionLength(0 ... 1))))% y te acerca al objetivo de \(grade(targetGrade))"
        }
        return "te acerca al objetivo de \(grade(targetGrade)) en \(subjectName)"
    }

    private func grade(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

enum AcademicPriorityEngine {
    static func contexts(
        subjects: [AcademicSubject],
        items: [SubjectGradeItem],
        tasks: [LumaTask]
    ) -> [UUID: AcademicPriorityContext] {
        let activeItems = items.filter { !$0.isArchived }
        let itemByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })
        var result: [UUID: AcademicPriorityContext] = [:]

        for subject in subjects where !subject.isArchived {
            guard let target = subject.targetGrade, (0 ... 10).contains(target) else { continue }
            let subjectTasks = tasks.filter { $0.academicSubjectID == subject.id }
            let subjectItems = activeItems.filter { $0.subjectID == subject.id }
            let summary = SubjectGradeCalculator.makeSummary(items: subjectItems, tasks: subjectTasks)
            let required = summary.requiredAverage(for: target)

            for task in subjectTasks where !task.isCompleted {
                result[task.id] = AcademicPriorityContext(
                    subjectName: subject.name,
                    targetGrade: target,
                    currentGrade: summary.currentGrade,
                    requiredAverage: required,
                    categoryWeight: task.subjectGradeItemID.flatMap { itemByID[$0]?.weightPercent }
                )
            }
        }
        return result
    }
}
