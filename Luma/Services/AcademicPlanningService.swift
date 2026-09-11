import Foundation
import CryptoKit
import SwiftData

struct AcademicPlanningService {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    @MainActor
    @discardableResult
    func materialize(
        routines: [AcademicRoutine],
        exams: [AcademicExam],
        tasks: [LumaTask],
        dailyContext: DailyPlanningContext?,
        in modelContext: ModelContext,
        saveChanges: Bool = true,
        now: Date = .now
    ) -> Int {
        var inserted = 0

        let currentTasks = (try? modelContext.fetch(FetchDescriptor<LumaTask>())) ?? tasks
        inserted += materializeRoutines(routines, tasks: currentTasks, in: modelContext, now: now)
        inserted += materializeExamStudy(exams, tasks: currentTasks, in: modelContext, now: now)
        inserted += materializeRestIfNeeded(context: dailyContext, tasks: currentTasks, in: modelContext, now: now)
        if inserted > 0 && saveChanges { try? modelContext.save() }
        return inserted
    }

    /// Repairs plans created before hierarchical syllabus topics were supported.
    /// A pending parent task such as "Estudiar: 1. Generalidades" is replaced by
    /// the leaf tasks 1.1, 1.2, etc. Completed work is intentionally preserved.
    @MainActor
    private func repairLegacyParentExamTasks(
        exams: [AcademicExam],
        tasks: [LumaTask],
        in modelContext: ModelContext
    ) -> Int {
        let subjects = (try? modelContext.fetch(FetchDescriptor<AcademicSubject>())) ?? []
        var inserted = 0

        for exam in exams where !exam.isArchived {
            guard let subject = subjects.first(where: { $0.id == exam.subjectID }) else { continue }
            let storedTopics = subject.syllabusStudyTopics
            let selectedParents = exam.topics.compactMap { selectedTitle in
                storedTopics.first {
                    normalizedTopicTitle($0.title) == normalizedTopicTitle(selectedTitle)
                        && !$0.syllabusSubtopics.isEmpty
                }
            }
            guard !selectedParents.isEmpty else { continue }

            let legacyParentTitles = Set(selectedParents.map {
                normalizedTopicTitle("Estudiar: \($0.title)")
            })
            let legacyParentTasks = tasks.filter {
                $0.sourceID == exam.id
                    && $0.academicSourceType == .examStudy
                    && !$0.isCompleted
                    && legacyParentTitles.contains(normalizedTopicTitle($0.title))
            }
            guard !legacyParentTasks.isEmpty else { continue }

            let pendingStudyTasks = tasks.filter {
                $0.sourceID == exam.id
                    && $0.academicSourceType == .examStudy
                    && !$0.isCompleted
            }
            let removedIDs = Set(pendingStudyTasks.map(\.id))
            pendingStudyTasks.forEach(modelContext.delete)

            let planningTopics = expandedLeafTopics(
                planningTopics(for: exam, subject: subject),
                examID: exam.id
            )
            exam.topics = planningTopics.map(\.title)
            exam.updatedAt = .now
            inserted += materializeGeneratedExamStudy(
                exam: exam,
                topics: planningTopics,
                sourceFileName: subject.syllabusSourceFileName,
                tasks: tasks.filter { !removedIDs.contains($0.id) },
                in: modelContext
            )

            #if DEBUG
            print("🧹 [PLAN-EXAMEN] Plan anterior corregido | examen=\(exam.title) | unidades padre eliminadas=\(legacyParentTasks.count) | subtemas=\(planningTopics.count)")
            #endif
        }
        return inserted
    }

    private func planningTopics(for exam: AcademicExam, subject: AcademicSubject) -> [StudyTopic] {
        let storedTopics = subject.syllabusStudyTopics
        let selectedTitles = exam.topics
        let minutesPerTopic = max(20, exam.preparationMinutes / max(1, selectedTitles.count))

        return selectedTitles.map { title in
            if var stored = storedTopics.first(where: {
                normalizedTopicTitle($0.title) == normalizedTopicTitle(title)
            }) {
                stored.suggestedMinutes = min(90, max(20, stored.suggestedMinutes))
                return stored
            }
            for parent in storedTopics {
                if let subtopic = parent.syllabusSubtopics.first(where: {
                    normalizedTopicTitle($0.displayTitle) == normalizedTopicTitle(title)
                }) {
                    return StudyTopic(
                        title: subtopic.displayTitle,
                        summary: "Subtema de \(parent.title) incluido en el examen de \(subject.name).",
                        keyPoints: [subtopic.displayTitle],
                        sourcePages: subtopic.sourcePages.isEmpty ? parent.sourcePages : subtopic.sourcePages,
                        importance: parent.importance,
                        suggestedMinutes: min(90, minutesPerTopic),
                        taskID: nil,
                        subtopics: [subtopic]
                    )
                }
            }
            return StudyTopic(
                title: title,
                summary: "Tema incluido en el examen de \(subject.name).",
                keyPoints: [],
                sourcePages: [],
                importance: 2,
                suggestedMinutes: minutesPerTopic,
                taskID: nil
            )
        }
    }

    @MainActor
    @discardableResult
    func materializeGeneratedExamStudy(
        exam: AcademicExam,
        topics: [StudyTopic],
        sourceFileName: String,
        tasks: [LumaTask],
        in modelContext: ModelContext
    ) -> Int {
        guard exam.shouldPrepare else { return 0 }
        let planningTopics = expandedLeafTopics(topics, examID: exam.id).map { topic in
            var stable = topic
            stable.id = deterministicUUID("exam-topic-\(exam.id)-\(normalizedTopicTitle(topic.title))")
            return stable
        }
        guard !planningTopics.isEmpty else { return 0 }
        let drafts = StudyScheduleBuilder.drafts(guideID: exam.id, guideTitle: exam.title,
            topics: planningTopics, examDate: exam.date, now: max(Date.now, exam.preparationStart), calendar: calendar)
        let previous = tasks.filter { $0.sourceID == exam.id && $0.academicSourceType == .examStudy }
        var matched = Set<UUID>()
        var inserted = 0
        for (index, draft) in drafts.enumerated() {
            let itemKey = draft.topicID?.uuidString ?? "review"
            let itemMarker = "LUMA-EXAM-TOPICS:\(exam.id.uuidString):\(itemKey)"
            let legacyReview = draft.topicID == nil
            let existing = previous.first { task in
                !matched.contains(task.id) && (task.notes.contains(itemMarker)
                    || normalizedTopicTitle(task.title) == normalizedTopicTitle(draft.title)
                    || (legacyReview && task.notes.contains("LUMA-STUDY-REVIEW")))
            }
            let task = existing ?? LumaTask(id: deterministicUUID("exam-pdf-\(exam.id)-\(itemKey)"),
                title: draft.title, area: .university, estimatedMinutes: draft.estimatedMinutes,
                energy: draft.energy, impact: .grade, academicSubjectID: exam.subjectID,
                sourceTypeRaw: AcademicTaskSourceType.examStudy.rawValue, sourceID: exam.id)
            matched.insert(task.id)
            task.title = draft.title
            task.dueDate = exam.date
            // A suggestion is a day in the shared plan, never an invented 19:00 appointment.
            if task.planningDetailsRaw == nil, let scheduled = task.deadline, calendar.component(.hour, from: scheduled) == 19, task.sourceOccurrenceDate.map({ calendar.isDate($0, inSameDayAs: scheduled) }) == true { task.deadline = nil }
            task.academicSubjectID = exam.subjectID
            task.academicWeight = exam.academicWeight
            task.sourceOccurrenceDate = draft.deadline
            task.notes = generatedTaskNotes(draftNotes: draft.notes, sourceFileName: sourceFileName, itemMarker: itemMarker)
            var details = task.planningDetails
            details.startDate = exam.preparationStart
            details.studyOrder = index
            details.isRetired = false
            task.planningDetails = details
            task.touch()
            if existing == nil { modelContext.insert(task); inserted += 1 }
        }
        for task in previous where !matched.contains(task.id) && !task.isCompleted {
            var details = task.planningDetails
            details.isRetired = true
            task.planningDetails = details
            task.touch()
        }
        return inserted
    }

    /// A syllabus unit is organizational only. When it has children, study tasks
    /// must be generated from the leaf subtopics (1.1, 1.2, ...), never from the
    /// parent unit itself (1, 2, ...).
    private func expandedLeafTopics(_ topics: [StudyTopic], examID: UUID) -> [StudyTopic] {
        topics.flatMap { topic -> [StudyTopic] in
            let subtopics = topic.syllabusSubtopics
            guard !subtopics.isEmpty else { return [topic] }

            // Topics selected from the new editor already represent a single leaf
            // and keep that leaf as metadata. Do not expand them a second time.
            if subtopics.count == 1,
               normalizedTopicTitle(topic.title) == normalizedTopicTitle(subtopics[0].displayTitle) {
                return [topic]
            }

            let minutesPerSubtopic = min(
                90,
                max(20, Int(ceil(Double(topic.suggestedMinutes) / Double(subtopics.count))))
            )
            return subtopics.map { subtopic in
                StudyTopic(
                    id: deterministicUUID(
                        "exam-leaf-\(examID.uuidString)-\(topic.id.uuidString)-\(subtopic.code)-\(subtopic.title)"
                    ),
                    title: subtopic.displayTitle,
                    summary: "Subtema de \(topic.title).",
                    keyPoints: [subtopic.displayTitle],
                    sourcePages: subtopic.sourcePages.isEmpty ? topic.sourcePages : subtopic.sourcePages,
                    importance: topic.importance,
                    suggestedMinutes: minutesPerSubtopic,
                    taskID: nil,
                    subtopics: [subtopic]
                )
            }
        }
    }

    private func normalizedTopicTitle(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generatedTaskNotes(
        draftNotes: String,
        sourceFileName: String,
        itemMarker: String
    ) -> String {
        let source = sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLine = source.isEmpty ? "" : "\nTemario PDF: \(source)"
        return "\(draftNotes)\(sourceLine)\n\(itemMarker)"
    }

    @MainActor
    private func materializeRoutines(
        _ routines: [AcademicRoutine],
        tasks: [LumaTask],
        in modelContext: ModelContext,
        now: Date
    ) -> Int {
        let start = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 21, to: start) ?? start
        var knownKeys = Set(tasks.compactMap { task -> String? in
            guard task.academicSourceType == .routine,
                  let sourceID = task.sourceID,
                  let date = task.sourceOccurrenceDate
            else { return nil }
            return occurrenceKey(sourceID: sourceID, date: date)
        })
        var inserted = 0

        for routine in routines where !routine.isPaused {
            let lowerBound = max(start, calendar.startOfDay(for: routine.startDate))
            let upperBound = min(horizon, routine.endDate.map { calendar.startOfDay(for: $0) } ?? horizon)
            guard lowerBound <= upperBound else { continue }

            var cursor = calendar.date(byAdding: .day, value: -1, to: lowerBound) ?? lowerBound
            while let occurrence = calendar.nextDate(
                after: cursor,
                matching: DateComponents(weekday: routine.weekday),
                matchingPolicy: .nextTime,
                direction: .forward
            ), occurrence <= upperBound {
                let day = calendar.startOfDay(for: occurrence)
                let key = occurrenceKey(sourceID: routine.id, date: day)
                if !knownKeys.contains(key) {
                    let deadline = date(on: day, minuteOfDay: routine.minuteOfDay ?? 0)
                    let task = LumaTask(
                        id: deterministicUUID("routine-\(key)"),
                        title: routine.title,
                        area: .university,
                        deadline: deadline,
                        estimatedMinutes: routine.estimatedMinutes,
                        energy: routine.activityType == .reading ? .medium : .high,
                        impact: .grade,
                        academicSubjectID: routine.subjectID,
                        notes: routine.notes,
                        sourceTypeRaw: AcademicTaskSourceType.routine.rawValue,
                        sourceID: routine.id,
                        sourceOccurrenceDate: day
                    )
                    modelContext.insert(task)
                    knownKeys.insert(key)
                    inserted += 1
                }
                cursor = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }
        }
        return inserted
    }

    @MainActor
    private func materializeExamStudy(
        _ exams: [AcademicExam],
        tasks: [LumaTask],
        in modelContext: ModelContext,
        now: Date
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        var knownKeys = Set(tasks.compactMap { task -> String? in
            guard task.academicSourceType == .examStudy,
                  let examID = task.sourceID,
                  let stage = task.studyStage
            else { return nil }
            return "\(examID.uuidString)-\(stage.rawValue)"
        })
        var inserted = 0

        for exam in exams where !exam.isArchived && exam.date >= today && exam.shouldPrepare {
            let existing = tasks.filter { $0.sourceID == exam.id && $0.academicSourceType == .examStudy }
            if existing.contains(where: { $0.notes.contains("LUMA-EXAM-TOPICS:") && $0.planningDetails.isRetired != true }) { continue }
            let stages = Array(ExamStudyStage.allCases)
            for (index, stage) in stages.enumerated() {
                let key = "\(exam.id.uuidString)-\(stage.rawValue)"
                let old = existing.first { $0.studyStage == stage }
                let task = old ?? LumaTask(id: deterministicUUID("exam-\(key)"),
                    title: "\(stage.title): \(exam.title)", area: .university,
                    estimatedMinutes: max(10, Int(ceil(Double(exam.preparationMinutes) / Double(stages.count)))),
                    energy: .medium, impact: .grade, academicSubjectID: exam.subjectID,
                    sourceTypeRaw: AcademicTaskSourceType.examStudy.rawValue, sourceID: exam.id, studyStageRaw: stage.rawValue)
                if task.planningDetailsRaw == nil, let scheduled = task.deadline, calendar.component(.hour, from: scheduled) == 19, task.sourceOccurrenceDate.map({ calendar.isDate($0, inSameDayAs: scheduled) }) == true { task.deadline = nil }
                task.title = "\(stage.title): \(exam.title)"
                task.dueDate = exam.date
                task.academicWeight = exam.academicWeight
                task.academicSubjectID = exam.subjectID
                task.notes = exam.topics.isEmpty
                    ? "Preparación orientativa, sin temario cargado. Usá el material que tengas; ajustá esta estimación después del primer avance."
                    : "Temas: \(exam.topics.joined(separator: ", "))"
                var details = task.planningDetails
                details.startDate = exam.preparationStart
                details.studyOrder = index
                details.isRetired = false
                task.planningDetails = details
                if old == nil { modelContext.insert(task); inserted += 1 }
            }
        }

        return inserted
    }

    @MainActor
    private func materializeRestIfNeeded(
        context: DailyPlanningContext?,
        tasks: [LumaTask],
        in modelContext: ModelContext,
        now: Date
    ) -> Int {
        guard let context, context.restCounts, context.availableMinutes > 0 else { return 0 }
        let suggestedRestMinutes = TaskPlanner.suggestedRestMinutes(
            availableMinutes: context.availableMinutes,
            preference: context.energy
        )
        // Keep the day's pause available even when the current plan reserves no
        // rest, so a later time increase can include it without creating a duplicate.
        let restMinutes = suggestedRestMinutes > 0
            ? suggestedRestMinutes
            : min(context.availableMinutes, context.energy == .tired ? 25 : 15)
        let today = calendar.startOfDay(for: now)
        let exists = tasks.contains {
            $0.academicSourceType == .rest
                && $0.sourceOccurrenceDate.map { calendar.isDate($0, inSameDayAs: today) } == true
        }
        guard !exists else { return 0 }

        let task = LumaTask(
            id: deterministicUUID("rest-\(dayKey(today))"),
            title: "Pausa de recuperación",
            area: .rest,
            estimatedMinutes: restMinutes,
            energy: .low,
            impact: .wellbeing,
            notes: "El descanso también forma parte del plan.",
            sourceTypeRaw: AcademicTaskSourceType.rest.rawValue,
            sourceOccurrenceDate: today
        )
        modelContext.insert(task)
        return 1
    }

    private func occurrenceKey(sourceID: UUID, date: Date) -> String {
        "\(sourceID.uuidString)-\(dayKey(date))"
    }

    private func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func deterministicUUID(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func date(on day: Date, minuteOfDay: Int) -> Date {
        calendar.date(
            bySettingHour: max(0, min(23, minuteOfDay / 60)),
            minute: max(0, min(59, minuteOfDay % 60)),
            second: 0,
            of: day
        ) ?? day
    }
}
