@testable import Luma
import SwiftData
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

    func testTwoHoursIncludeThreeWorkBlocksAndSeparateRest() throws {
        let setup = fixedDay()
        let tasks = planningTasks(now: setup.now)
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 120, restCounts: true)

        let result = planner.planningResult(from: tasks, now: setup.now)

        XCTAssertEqual(result.primary.map(\.task.id), tasks.prefix(3).map(\.id))
        XCTAssertEqual(result.primary.map(\.suggestedMinutes), [45, 45, 15])
        XCTAssertEqual(try XCTUnwrap(result.rest).task.id, tasks[3].id)
        XCTAssertEqual(result.rest?.suggestedMinutes, 15)
        XCTAssertEqual(totalMinutes(result), 120)
        XCTAssertNil(result.optional)

        let onePriority = planner.planningResult(from: Array(tasks.suffix(2)), now: setup.now)
        XCTAssertEqual(onePriority.primary.map(\.task.id), [tasks[2].id])
        XCTAssertNil(onePriority.optional, "El descanso no debe reaparecer como otra tarea opcional")
        XCTAssertEqual(onePriority.rest?.task.id, tasks[3].id)
    }

    func testSmallBudgetsAreNeverExceededEvenWithUrgentWorkAndRest() {
        let setup = fixedDay()
        let tasks = planningTasks(now: setup.now)

        for restCounts in [false, true] {
            for budget in [0, 5, 15] {
                let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: budget, restCounts: restCounts)
                let result = planner.planningResult(from: tasks, now: setup.now)

                XCTAssertLessThanOrEqual(totalMinutes(result), budget, "Presupuesto de \(budget) min")
                XCTAssertTrue(result.primary.allSatisfy { $0.suggestedMinutes > 0 })
                if let rest = result.rest { XCTAssertGreaterThan(rest.suggestedMinutes, 0) }
                XCTAssertTrue(result.needsCapacityDecision)
            }
        }
    }

    func testPlanningModesUseTheDeclaredTimeWithoutMultiplyingIt() {
        let setup = fixedDay()
        let tasks = Array(planningTasks(now: setup.now).prefix(3))

        for mode in PlanningMode.allCases {
            let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 60, planningMode: mode)
            let result = planner.planningResult(from: tasks, now: setup.now)

            XCTAssertEqual(totalMinutes(result), 60, "Modo \(mode.rawValue)")
            XCTAssertLessThanOrEqual(result.primary.count, 3)
        }
    }

    func testEnergizedModeStillCapsEveryWorkBlockAtFortyFiveMinutes() {
        let setup = fixedDay()
        let tasks = planningTasks(now: setup.now)
        let planner = TaskPlanner(
            calendar: setup.calendar,
            preferredBlockOverride: 90,
            availableMinutes: 180,
            planningMode: .intense
        )

        let result = planner.planningResult(from: tasks, now: setup.now, preference: .energized)

        XCTAssertEqual(result.primary.count, 3)
        XCTAssertTrue(result.primary.allSatisfy { $0.suggestedMinutes == 45 })
    }

    func testTiredPlanKeepsUrgentHighEnergyWorkAndReplacesNonurgentHighEnergyWork() throws {
        let setup = fixedDay()
        let urgent = LumaTask(
            title: "Entregar mañana",
            area: .university,
            dueDate: setup.now.addingTimeInterval(86400),
            estimatedMinutes: 90,
            energy: .high,
            // Keep creation before the fixed delivery day, regardless of the real clock.
            createdAt: setup.now
        )
        let nonurgent = LumaTask(
            title: "Proyecto largo",
            area: .home,
            estimatedMinutes: 90,
            energy: .high
        )
        let light = LumaTask(title: "Preparar materiales", area: .home, estimatedMinutes: 30, energy: .low)
        let rest = planningTasks(now: setup.now)[3]
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 120, restCounts: true)

        let result = planner.planningResult(
            from: [nonurgent, rest, light, urgent],
            now: setup.now,
            preference: .tired
        )

        XCTAssertEqual(Set(result.primary.map(\.task.id)), Set([urgent.id, light.id]))
        XCTAssertTrue(result.primary.allSatisfy { $0.suggestedMinutes <= 25 })
        XCTAssertEqual(try XCTUnwrap(result.rest).suggestedMinutes, 25)
    }

    func testThirtyTiredMinutesKeepTwentyMinutesForWorkAndTenForRest() throws {
        let setup = fixedDay()
        let work = LumaTask(title: "Ordenar apuntes", area: .university, estimatedMinutes: 90, energy: .low)
        let existingRest = planningTasks(now: setup.now)[3]
        existingRest.estimatedMinutes = 15 // Reproduce a pause created with the previous default.
        XCTAssertEqual(existingRest.estimatedMinutes, 15)
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 30, restCounts: true)

        let result = planner.planningResult(from: [work, existingRest], now: setup.now, preference: .tired)

        XCTAssertEqual(result.primary.map(\.task.id), [work.id])
        XCTAssertEqual(result.primary.map(\.suggestedMinutes), [20])
        XCTAssertEqual(try XCTUnwrap(result.rest).suggestedMinutes, 10)
        XCTAssertEqual(totalMinutes(result), 30)
        XCTAssertNil(result.optional)
    }

    func testAdaptiveRestAndUsefulBlocksRespectVerySmallBudgets() {
        let setup = fixedDay()
        let work = (0 ..< 4).map {
            LumaTask(title: "Pendiente \($0)", area: .home, estimatedMinutes: 90, energy: .low)
        }
        let tasks = work + [planningTasks(now: setup.now)[3]]

        for preference in [EnergyPreference.normal, .tired, .energized] {
            for budget in [0, 1, 5, 9, 10, 14, 15, 20, 29, 30, 40, 60, 69, 120] {
                let result = TaskPlanner(calendar: setup.calendar, availableMinutes: budget, restCounts: true)
                    .planningResult(from: tasks, now: setup.now, preference: preference)

                XCTAssertLessThanOrEqual(totalMinutes(result), budget, "\(preference), \(budget) min")
                XCTAssertLessThanOrEqual(result.primary.count, preference == .tired ? 2 : 3)
                XCTAssertTrue(result.primary.allSatisfy {
                    $0.suggestedMinutes >= 10 && $0.suggestedMinutes <= (preference == .tired ? 25 : 45)
                })
                if let optional = result.optional { XCTAssertGreaterThanOrEqual(optional.suggestedMinutes, 10) }
                if budget < 10 { XCTAssertTrue(result.primary.isEmpty) }
                if budget > 0, budget < 10 { XCTAssertEqual(result.rest?.suggestedMinutes, budget) }
                if budget == 0 || (10 ..< 15).contains(budget) { XCTAssertNil(result.rest) }
            }
        }
    }

    func testSmallRemainderStaysFreeInsteadOfStartingAnotherWorkBlock() {
        let setup = fixedDay()
        let tasks = (0 ..< 3).map {
            LumaTask(title: "Pendiente \($0)", area: .home, estimatedMinutes: 90, energy: .low)
        } + [planningTasks(now: setup.now)[3]]
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 69, restCounts: true)

        let result = planner.planningResult(from: tasks, now: setup.now)

        XCTAssertEqual(result.primary.map(\.suggestedMinutes), [45])
        XCTAssertEqual(result.rest?.suggestedMinutes, 15)
        XCTAssertEqual(totalMinutes(result), 60)
        XCTAssertNil(result.optional)
        XCTAssertNil(planner.optionalRecommendation(
            from: tasks,
            excluding: Set(result.primary.map(\.id)),
            now: setup.now
        ))
    }

    func testAdaptiveRestDoesNotChangeSavedWorkWhenRestIsCompletedAndRestored() throws {
        let setup = fixedDay()
        let work = LumaTask(title: "Preparar materiales", area: .home, estimatedMinutes: 90, energy: .low)
        let rest = planningTasks(now: setup.now)[3]
        rest.estimatedMinutes = 15 // The shared fixture uses 30; this case covers the previous 15-minute pause.
        let tasks = [work, rest]
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 30, restCounts: true)
        let savedMinutes = [work.id: 20]

        func savedWorkMinutes() -> [Int] {
            planner.recommendationsPreservingPlan(
                from: tasks,
                taskIDs: [work.id],
                now: setup.now,
                preference: .tired,
                savedMinutes: savedMinutes,
                savedRestMinutes: 10
            ).map(\.suggestedMinutes)
        }

        XCTAssertEqual(try XCTUnwrap(planner.restRecommendation(from: tasks, now: setup.now, preference: .tired)).suggestedMinutes, 10)
        XCTAssertEqual(savedWorkMinutes(), [20])
        rest.markCompleted()
        XCTAssertNil(planner.restRecommendation(from: tasks, now: setup.now, preference: .tired))
        XCTAssertEqual(savedWorkMinutes(), [20], "Completar la pausa no alarga un bloque ya confirmado")
        rest.restore()
        XCTAssertEqual(planner.restRecommendation(from: tasks, now: setup.now, preference: .tired)?.suggestedMinutes, 10)
        XCTAssertEqual(savedWorkMinutes(), [20])
        XCTAssertEqual(rest.estimatedMinutes, 15, "Una pausa creada antes conserva su identidad; su duración sugerida se adapta")
    }

    func testConfirmedRestKeepsItsMinutesWhenOnlyTheRestBudgetRemains() throws {
        let setup = fixedDay()
        let rest = planningTasks(now: setup.now)[3]
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 10, restCounts: true)

        XCTAssertNil(planner.restRecommendation(from: [rest], now: setup.now, preference: .tired))
        XCTAssertEqual(try XCTUnwrap(planner.restRecommendation(
            from: [rest], now: setup.now, preference: .tired, savedMinutes: 10
        )).suggestedMinutes, 10, "Una pausa confirmada no se recalcula como si los diez minutos fueran un día nuevo")
        rest.markCompleted()
        XCTAssertNil(planner.restRecommendation(from: [rest], now: setup.now, preference: .tired, savedMinutes: 10))
        rest.restore()
        XCTAssertEqual(planner.restRecommendation(from: [rest], now: setup.now, preference: .tired, savedMinutes: 10)?.suggestedMinutes, 10)
        XCTAssertEqual(planner.restRecommendation(
            from: [rest], now: setup.now, preference: .tired, budgetOverride: 5, savedMinutes: 10
        )?.suggestedMinutes, 5, "Una reserva anterior tampoco puede superar el saldo disponible")

        let work = LumaTask(title: "Preparar materiales", area: .home, estimatedMinutes: 90, energy: .low)
        let originalPlanner = TaskPlanner(calendar: setup.calendar, availableMinutes: 120, restCounts: true)
        XCTAssertTrue(originalPlanner.recommendationsPreservingPlan(
            from: [work, rest],
            taskIDs: [work.id],
            now: setup.now,
            preference: .tired,
            savedMinutes: [work.id: 20],
            savedRestMinutes: 10,
            budgetOverride: 10
        ).isEmpty, "El saldo actualizado prevalece aunque el planificador conserve el presupuesto inicial")
    }

    func testPreviouslySavedShortWorkBlockIsStillPreserved() {
        let setup = fixedDay()
        let work = LumaTask(title: "Bloque ya confirmado", area: .home, estimatedMinutes: 30, energy: .low)
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 5, restCounts: false)

        XCTAssertTrue(planner.planningResult(from: [work], now: setup.now).primary.isEmpty)
        XCTAssertEqual(planner.recommendationsPreservingPlan(
            from: [work], taskIDs: [work.id], now: setup.now, savedMinutes: [work.id: 5]
        ).map(\.suggestedMinutes), [5], "El mínimo de diez minutos solo se aplica a nuevos bloques")
    }

    @MainActor
    func testMaterializedRestUsesTheSameDurationAsTheTiredPlan() throws {
        let setup = fixedDay()
        let schema = Schema([LumaTask.self, AcademicSubject.self])
        let configuration = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try SwiftData.ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let dailyContext = DailyPlanningContext(day: setup.now, energy: .tired, availableMinutes: 30, restCounts: true)
        let service = AcademicPlanningService(calendar: setup.calendar)

        XCTAssertEqual(service.materialize(
            routines: [], exams: [], tasks: [], dailyContext: dailyContext, in: modelContext, now: setup.now
        ), 1)
        let rest = try XCTUnwrap(modelContext.fetch(FetchDescriptor<LumaTask>()).first)
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 30, restCounts: true)
        XCTAssertEqual(rest.estimatedMinutes, 10)
        XCTAssertEqual(planner.restRecommendation(from: [rest], now: setup.now, preference: .tired)?.suggestedMinutes, 10)
        XCTAssertEqual(service.materialize(
            routines: [], exams: [], tasks: [rest], dailyContext: dailyContext, in: modelContext, now: setup.now
        ), 0)
    }

    @MainActor
    func testRestCreatedForTenMinutesCanBeIncludedAfterAddingTime() throws {
        let setup = fixedDay()
        let schema = Schema([LumaTask.self, AcademicSubject.self])
        let configuration = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try SwiftData.ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let dailyContext = DailyPlanningContext(day: setup.now, energy: .tired, availableMinutes: 10, restCounts: true)
        let service = AcademicPlanningService(calendar: setup.calendar)

        XCTAssertEqual(service.materialize(
            routines: [], exams: [], tasks: [], dailyContext: dailyContext, in: modelContext, now: setup.now
        ), 1)
        let rest = try XCTUnwrap(modelContext.fetch(FetchDescriptor<LumaTask>()).first)
        XCTAssertEqual(rest.estimatedMinutes, 10)
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 10, restCounts: true)
        XCTAssertNil(planner.restRecommendation(from: [rest], now: setup.now, preference: .tired))

        // Adding thirty minutes can use the existing pause in the preview; it
        // does not need to insert a new task before the user applies the change.
        XCTAssertEqual(planner.restRecommendation(
            from: [rest], now: setup.now, preference: .tired, budgetOverride: 40
        )?.suggestedMinutes, 13)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<LumaTask>()).count, 1)
        XCTAssertEqual(rest.estimatedMinutes, 10)
    }

    func testDeclaredFreeTimeIsNotDiscountedAgainForClasses() throws {
        let setup = fixedDay()
        let task = planningTasks(now: setup.now)[0]
        task.estimatedMinutes = 30
        let meeting = SubjectClassMeeting(
            subjectID: UUID(),
            weekday: setup.calendar.component(.weekday, from: setup.now),
            startMinuteOfDay: 10 * 60,
            endMinuteOfDay: 16 * 60
        )
        let withoutClasses = TaskPlanner(calendar: setup.calendar, availableMinutes: 30)
            .planningResult(from: [task], now: setup.now)
        let withClasses = TaskPlanner(calendar: setup.calendar, availableMinutes: 30, classMeetings: [meeting])
            .planningResult(from: [task], now: setup.now)

        XCTAssertEqual(totalMinutes(withClasses), 30)
        XCTAssertEqual(
            try XCTUnwrap(withClasses.primary.first).score,
            try XCTUnwrap(withoutClasses.primary.first).score,
            accuracy: 0.001
        )
    }

    func testTomorrowDeliveryTakesPriorityTodayAndInsufficientCapacityIsReported() {
        let setup = fixedDay()
        let tasks = planningTasks(now: setup.now)
        let planner = TaskPlanner(calendar: setup.calendar, availableMinutes: 15)

        let result = planner.planningResult(from: [tasks[2], tasks[0]], now: setup.now)

        XCTAssertEqual(result.primary.map(\.task.id), [tasks[0].id])
        XCTAssertEqual(result.primary.first?.suggestedMinutes, 15)
        XCTAssertTrue(result.needsCapacityDecision)
    }

    @MainActor
    func testRestIsCreatedOnceEvenOnALightDayAndRespectsRestSettings() throws {
        let setup = fixedDay()
        let schema = Schema([LumaTask.self, AcademicSubject.self])
        let configuration = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try SwiftData.ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let dailyContext = DailyPlanningContext(day: setup.now, availableMinutes: 120, restCounts: false)
        let service = AcademicPlanningService(calendar: setup.calendar)

        func materialize() -> Int {
            service.materialize(
                routines: [],
                exams: [],
                tasks: [],
                dailyContext: dailyContext,
                in: modelContext,
                now: setup.now
            )
        }

        XCTAssertEqual(materialize(), 0)
        dailyContext.restCounts = true
        dailyContext.availableMinutes = 0
        XCTAssertEqual(materialize(), 0)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LumaTask>()).isEmpty)

        dailyContext.availableMinutes = 120
        XCTAssertEqual(materialize(), 1)
        let rest = try XCTUnwrap(modelContext.fetch(FetchDescriptor<LumaTask>()).first)
        XCTAssertEqual(rest.academicSourceType, .rest)
        XCTAssertEqual(rest.estimatedMinutes, 15)
        XCTAssertEqual(rest.sourceOccurrenceDate, setup.calendar.startOfDay(for: setup.now))
        XCTAssertNil(rest.deadline)

        XCTAssertEqual(materialize(), 0)
        rest.markCompleted()
        try modelContext.save()
        XCTAssertEqual(materialize(), 0)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<LumaTask>()).count, 1)
    }

    private func fixedDay() -> (calendar: Calendar, now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 9))!
        return (calendar, now)
    }

    private func planningTasks(now: Date) -> [LumaTask] {
        [
            LumaTask(
                title: "Primera entrega",
                area: .university,
                dueDate: now.addingTimeInterval(86400),
                estimatedMinutes: 90,
                energy: .high,
                createdAt: now.addingTimeInterval(-3600)
            ),
            LumaTask(
                title: "Segunda entrega",
                area: .sideHustle,
                dueDate: now.addingTimeInterval(86400),
                estimatedMinutes: 90,
                energy: .high,
                createdAt: now.addingTimeInterval(-1800)
            ),
            LumaTask(
                title: "Adelantar pendiente",
                area: .home,
                dueDate: now.addingTimeInterval(7 * 86400),
                estimatedMinutes: 90,
                createdAt: now
            ),
            LumaTask(
                title: "Descanso",
                area: .hobbies,
                estimatedMinutes: 30,
                energy: .low,
                impact: .wellbeing,
                createdAt: now,
                sourceTypeRaw: AcademicTaskSourceType.rest.rawValue,
                sourceOccurrenceDate: now
            ),
        ]
    }

    private func totalMinutes(_ result: DailyPlanResult) -> Int {
        result.primary.reduce(0) { $0 + $1.suggestedMinutes } + (result.rest?.suggestedMinutes ?? 0)
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
        XCTAssertEqual(summary.upcomingEvaluationTaskCount, 1)
        XCTAssertEqual(summary.awaitingGradeTaskCount, 0)
        XCTAssertEqual(summary.gradedWeight, 80, accuracy: 0.001)
        XCTAssertEqual(summary.weightedContribution, 7, accuracy: 0.001)
        XCTAssertEqual(summary.currentGrade ?? -1, 8.75, accuracy: 0.001)
        XCTAssertEqual(summary.requiredAverage(for: 8.5) ?? -1, 7.5, accuracy: 0.001)
    }

    func testAcademicEvaluationLifecycleSeparatesUpcomingFromAwaitingGrade() {
        let subjectID = UUID()
        let categoryID = UUID()
        let evaluation = LumaTask(
            title: "Parcial",
            area: .university,
            academicSubjectID: subjectID,
            subjectGradeItemID: categoryID
        )

        XCTAssertEqual(evaluation.academicEvaluationStatus, .upcomingEvaluation)

        evaluation.markCompleted()
        XCTAssertEqual(evaluation.academicEvaluationStatus, .awaitingGrade)

        evaluation.grade = 8.5
        XCTAssertEqual(evaluation.academicEvaluationStatus, .graded)
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

}
