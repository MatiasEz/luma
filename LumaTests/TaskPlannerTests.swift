@testable import Luma
import XCTest

final class TaskPlannerTests: XCTestCase {
    func testReturnsOnlyThreePriorities() {
        let tasks = (0 ..< 6).map { index in
            LumaTask(
                title: "Tarea \(index)",
                area: LifeArea.allCases[index % LifeArea.allCases.count],
                deadline: Date.now.addingTimeInterval(Double(index + 1) * 86400),
                estimatedMinutes: 30,
                energy: .medium,
                impact: .general
            )
        }

        let recommendations = TaskPlanner().recommendations(from: tasks)
        XCTAssertEqual(recommendations.count, 3)
    }

    func testTiredModeAvoidsHighEnergyWhenComparable() {
        let deadline = Date.now.addingTimeInterval(2 * 86400)
        let high = LumaTask(
            title: "Trabajo profundo",
            area: .university,
            deadline: deadline,
            estimatedMinutes: 45,
            energy: .high,
            impact: .general
        )
        let low = LumaTask(
            title: "Ordenar papeles",
            area: .errands,
            deadline: deadline,
            estimatedMinutes: 30,
            energy: .low,
            impact: .general
        )

        let recommendations = TaskPlanner().recommendations(
            from: [high, low],
            preference: .tired,
            limit: 1
        )

        XCTAssertEqual(recommendations.first?.task.id, low.id)
        XCTAssertEqual(recommendations.first?.suggestedMinutes, 25)
    }

    func testAcademicWeightRaisesPriority() {
        let deadline = Date.now.addingTimeInterval(5 * 86400)
        let weighted = LumaTask(
            title: "Entrega importante",
            area: .university,
            deadline: deadline,
            energy: .medium,
            impact: .grade,
            academicWeight: 35
        )
        let unweighted = LumaTask(
            title: "Lectura opcional",
            area: .university,
            deadline: deadline,
            energy: .medium,
            impact: .general
        )

        let recommendations = TaskPlanner().recommendations(from: [unweighted, weighted], limit: 1)
        XCTAssertEqual(recommendations.first?.task.id, weighted.id)
    }

    func testCalculatesAverageNeededWithoutTreatingPendingGradesAsZero() {
        let subjectID = UUID()
        let exams = SubjectGradeItem(subjectID: subjectID, title: "Exámenes", weightPercent: 40)
        let assignments = SubjectGradeItem(subjectID: subjectID, title: "Tareas", weightPercent: 60)
        let firstExam = LumaTask(
            title: "Examen 1",
            area: .university,
            academicSubjectID: subjectID,
            subjectGradeItemID: exams.id,
            grade: 8
        )
        let pendingExam = LumaTask(
            title: "Examen 2",
            area: .university,
            academicSubjectID: subjectID,
            subjectGradeItemID: exams.id
        )
        let assignment = LumaTask(
            title: "Tareas",
            area: .university,
            academicSubjectID: subjectID,
            subjectGradeItemID: assignments.id,
            grade: 9
        )

        let summary = SubjectGradeCalculator.makeSummary(
            items: [exams, assignments],
            tasks: [firstExam, pendingExam, assignment]
        )

        XCTAssertEqual(summary.pendingGradeTaskCount, 1)
        XCTAssertEqual(summary.requiredAverage(for: 8.5) ?? -1, 7.5, accuracy: 0.001)
    }

    func testSimulatorOverrideProducesFinalGradeWithoutChangingTask() {
        let subjectID = UUID()
        let exams = SubjectGradeItem(subjectID: subjectID, title: "Exámenes", weightPercent: 100)
        let graded = LumaTask(
            title: "Examen 1",
            area: .university,
            academicSubjectID: subjectID,
            subjectGradeItemID: exams.id,
            grade: 8
        )
        let pending = LumaTask(
            title: "Examen 2",
            area: .university,
            academicSubjectID: subjectID,
            subjectGradeItemID: exams.id
        )

        let simulated = SubjectGradeCalculator.makeSummary(
            items: [exams],
            tasks: [graded, pending],
            simulatedGrades: [pending.id: 10]
        )

        XCTAssertEqual(simulated.finalGrade ?? -1, 9, accuracy: 0.001)
        XCTAssertNil(pending.grade)
    }

    func testAcademicGoalRiskRaisesRelatedTaskPriority() {
        let deadline = Date.now.addingTimeInterval(5 * 86400)
        let academic = LumaTask(
            title: "Preparar parcial",
            area: .university,
            deadline: deadline,
            energy: .medium,
            impact: .general
        )
        let other = LumaTask(
            title: "Ordenar apuntes",
            area: .university,
            deadline: deadline,
            energy: .medium,
            impact: .general
        )
        let context = AcademicPriorityContext(
            subjectName: "Economía",
            targetGrade: 8,
            currentGrade: 6.5,
            requiredAverage: 8.8,
            categoryWeight: 40
        )

        let recommendations = TaskPlanner(
            academicContexts: [academic.id: context]
        ).recommendations(from: [other, academic], limit: 1)

        XCTAssertEqual(recommendations.first?.task.id, academic.id)
        XCTAssertTrue(recommendations.first?.reason.contains("objetivo") == true)
    }
}
