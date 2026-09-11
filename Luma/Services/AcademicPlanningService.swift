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
        now: Date = .now
    ) -> Int {
        var inserted = 0
        inserted += repairLegacyParentExamTasks(exams: exams, tasks: tasks, in: modelContext)
        let currentTasks = (try? modelContext.fetch(FetchDescriptor<LumaTask>())) ?? tasks
        inserted += materializeRoutines(routines, tasks: currentTasks, in: modelContext, now: now)
        inserted += materializeExamStudy(exams, tasks: currentTasks, in: modelContext, now: now)
        inserted += materializeRestIfNeeded(context: dailyContext, tasks: currentTasks, in: modelContext, now: now)
        if inserted > 0 { try? modelContext.save() }
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
        let planningTopics = expandedLeafTopics(topics, examID: exam.id)
        guard !planningTopics.isEmpty else { return 0 }

        #if DEBUG
        print("🗓️ [PLAN-EXAMEN] Generando plan | examen=\(exam.title) | fecha=\(exam.date.formatted(date: .numeric, time: .omitted)) | temas finales=\(planningTopics.count)")
        for (index, topic) in planningTopics.enumerated() {
            print("   #\(index + 1) \(topic.title) | páginas=\(topic.pageLabel) | importancia=\(topic.importance) | duración base=\(topic.suggestedMinutes)m")
        }
        #endif

        let planMarker = "LUMA-EXAM-TOPICS:\(exam.id.uuidString)"
        let drafts = StudyScheduleBuilder.drafts(
            guideID: exam.id,
            guideTitle: exam.title,
            topics: planningTopics,
            examDate: exam.date
        )
        var inserted = 0

        for draft in drafts {
            let itemKey = draft.topicID?.uuidString ?? "review"
            let itemMarker = "\(planMarker):\(itemKey)"
            let stableStudyMarker = draft.topicID
                .map { "LUMA-STUDY-TOPIC:\($0.uuidString)" }
                ?? "LUMA-STUDY-REVIEW"
            guard !tasks.contains(where: {
                $0.sourceID == exam.id
                    && ($0.notes.contains(itemMarker) || $0.notes.contains(stableStudyMarker))
            }) else {
                #if DEBUG
                print("⏭️ [PLAN-EXAMEN] Omitida por duplicada | \(draft.title)")
                #endif
                continue
            }

            let scheduledDay = calendar.startOfDay(for: draft.deadline)
            let task = LumaTask(
                id: deterministicUUID("exam-pdf-\(exam.id.uuidString)-\(itemKey)"),
                title: draft.title,
                area: .university,
                dueDate: exam.date,
                deadline: date(on: scheduledDay, minuteOfDay: 19 * 60),
                estimatedMinutes: draft.estimatedMinutes,
                energy: draft.energy,
                impact: .grade,
                academicWeight: exam.importance.scoreBoost,
                academicSubjectID: exam.subjectID,
                notes: generatedTaskNotes(
                    draftNotes: draft.notes,
                    sourceFileName: sourceFileName,
                    itemMarker: itemMarker
                ),
                sourceTypeRaw: AcademicTaskSourceType.examStudy.rawValue,
                sourceID: exam.id,
                sourceOccurrenceDate: scheduledDay
            )
            modelContext.insert(task)
            inserted += 1

            #if DEBUG
            print("✅ [PLAN-EXAMEN] Tarea creada | \(task.title) | fecha=\(task.deadline?.formatted(date: .numeric, time: .shortened) ?? "sin fecha") | duración=\(task.estimatedMinutes)m | energía=\(task.energy.title)")
            #endif
        }

        if inserted > 0 { try? modelContext.save() }
        #if DEBUG
        print("🏁 [PLAN-EXAMEN] Plan terminado | tareas nuevas=\(inserted)")
        #endif
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
                    let deadline = date(on: day, minuteOfDay: routine.minuteOfDay ?? 18 * 60)
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

        for exam in exams where !exam.isArchived && exam.date > today && !exam.topics.isEmpty {
            let hasGeneratedTopicPlan = tasks.contains {
                $0.sourceID == exam.id
                    && $0.academicSourceType == .examStudy
                    && (
                        $0.notes.contains("LUMA-EXAM-TOPICS:\(exam.id.uuidString)")
                            || $0.notes.contains("LUMA-EXAM-PDF:\(exam.id.uuidString)")
                    )
            }
            guard !hasGeneratedTopicPlan else { continue }

            let examDay = calendar.startOfDay(for: exam.date)
            let lastStudyDay = calendar.date(byAdding: .day, value: -1, to: examDay) ?? today
            let availableDays = max(1, calendar.dateComponents([.day], from: today, to: lastStudyDay).day ?? 1)
            let minutesPerStage = max(20, Int(ceil(Double(exam.preparationMinutes) / Double(ExamStudyStage.allCases.count))))

            for (index, stage) in ExamStudyStage.allCases.enumerated() {
                let key = "\(exam.id.uuidString)-\(stage.rawValue)"
                guard !knownKeys.contains(key) else { continue }
                let progress = Double(index + 1) / Double(ExamStudyStage.allCases.count)
                let dayOffset = min(availableDays, max(0, Int((Double(availableDays) * progress).rounded(.down))))
                let scheduledDay = min(
                    calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today,
                    lastStudyDay
                )
                let topicSummary = exam.topics.prefix(3).joined(separator: ", ")
                let task = LumaTask(
                    id: deterministicUUID("exam-\(key)"),
                    title: "\(stage.title): \(exam.title)",
                    area: .university,
                    dueDate: exam.date,
                    deadline: date(on: scheduledDay, minuteOfDay: 19 * 60),
                    estimatedMinutes: minutesPerStage,
                    energy: stage == .read || stage == .summarize ? .high : .medium,
                    impact: .grade,
                    academicWeight: exam.importance.scoreBoost,
                    academicSubjectID: exam.subjectID,
                    notes: topicSummary.isEmpty ? "Preparación para \(exam.title)" : "Temas: \(topicSummary)",
                    sourceTypeRaw: AcademicTaskSourceType.examStudy.rawValue,
                    sourceID: exam.id,
                    sourceOccurrenceDate: scheduledDay,
                    studyStageRaw: stage.rawValue
                )
                modelContext.insert(task)
                knownKeys.insert(key)
                inserted += 1
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
