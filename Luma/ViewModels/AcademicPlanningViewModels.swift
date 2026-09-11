import Foundation
import Observation

@MainActor
@Observable
final class RoutinesViewModel {
    var editorPresented = false

    func activeRoutines(from routines: [AcademicRoutine]) -> [AcademicRoutine] {
        routines.sorted {
            if $0.isPaused != $1.isPaused { return !$0.isPaused }
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            return ($0.minuteOfDay ?? 24 * 60) < ($1.minuteOfDay ?? 24 * 60)
        }
    }

    func subjectName(for routine: AcademicRoutine, subjects: [AcademicSubject]) -> String {
        guard let id = routine.subjectID else { return "Sin materia" }
        return subjects.first { $0.id == id }?.name ?? "Sin materia"
    }
}

@MainActor
@Observable
final class RoutineEditorViewModel {
    var title = ""
    var subjectID: UUID?
    var weekday = 3
    var hasTime = false
    var minuteOfDay = 17 * 60
    var activityType: AcademicActivityType = .assignment
    var estimatedMinutes = 40
    var startDate = Date.now
    var hasEndDate = false
    var endDate = Calendar.current.date(byAdding: .month, value: 4, to: .now) ?? .now
    var pauseDuringVacation = true

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
@Observable
final class ExamsViewModel {
    var editorPresented = false
    var editingExam: AcademicExam?

    func presentNewExam() {
        editingExam = nil
        editorPresented = true
    }

    func presentEditor(for exam: AcademicExam) {
        editingExam = exam
        editorPresented = true
    }

    func editorDismissed() {
        editingExam = nil
    }

    func upcoming(from exams: [AcademicExam]) -> [AcademicExam] {
        exams.filter { !$0.isArchived }.sorted { $0.date < $1.date }
    }

    func subjectName(for exam: AcademicExam, subjects: [AcademicSubject]) -> String {
        subjects.first { $0.id == exam.subjectID }?.name ?? "Materia"
    }

    func completedStages(for exam: AcademicExam, tasks: [LumaTask]) -> Set<ExamStudyStage> {
        Set(tasks.compactMap { task in
            guard task.sourceID == exam.id, task.academicSourceType == .examStudy, task.isCompleted else { return nil }
            return task.studyStage
        })
    }

    func studyTasks(for exam: AcademicExam, tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { $0.sourceID == exam.id && $0.academicSourceType == .examStudy }
    }

    func usesGeneratedTopicPlan(for exam: AcademicExam, tasks: [LumaTask]) -> Bool {
        studyTasks(for: exam, tasks: tasks).contains {
            $0.notes.contains("LUMA-EXAM-TOPICS:") || $0.notes.contains("LUMA-EXAM-PDF:")
        }
    }
}

@MainActor
@Observable
final class ExamEditorViewModel {
    var title = ""
    var subjectID: UUID?
    var date = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    var preparationStartDate = Date.now
    var preparationEnabled = true
    var academicWeight: Double?
    var topicsRaw = ""
    var selectedTopicKeys: Set<String> = []
    var importance: ExamImportance = .important
    var preparationMinutes = 300
    @ObservationIgnored private var originalTopicTitles: [String]
    @ObservationIgnored private var didConfigureExistingTopics: Bool

    init(exam: AcademicExam? = nil) {
        if let exam {
            title = exam.title
            subjectID = exam.subjectID
            date = exam.date
            preparationStartDate = exam.preparationStart
            preparationEnabled = exam.shouldPrepare
            academicWeight = exam.academicWeight
            importance = exam.importance
            preparationMinutes = exam.preparationMinutes
            originalTopicTitles = exam.topics
            selectedTopicKeys = Set(exam.topics.map(Self.normalizedValue))
            didConfigureExistingTopics = false
        } else {
            originalTopicTitles = []
            didConfigureExistingTopics = true
        }
    }

    func canSave(subjects: [AcademicSubject]) -> Bool {
        guard subjectID.flatMap({ id in subjects.first { !$0.isArchived && $0.id == id } }) != nil else {
            return false
        }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && date >= Calendar.current.startOfDay(for: .now)
    }

    func configureExistingTopics(for subject: AcademicSubject) {
        guard !didConfigureExistingTopics, subject.id == subjectID else { return }
        let syllabusKeys = Set(selectableTopicTitles(for: subject).map(Self.normalizedValue))
        var selectedKeys = Set<String>()
        var manualTitles: [String] = []
        for originalTitle in originalTopicTitles {
            let key = Self.normalizedValue(originalTitle)
            if syllabusKeys.contains(key) {
                selectedKeys.insert(key)
            } else if let parent = subject.syllabusStudyTopics.first(where: {
                Self.normalizedValue($0.title) == key && !$0.syllabusSubtopics.isEmpty
            }) {
                selectedKeys.formUnion(selectableTitles(for: parent).map(Self.normalizedValue))
            } else {
                manualTitles.append(originalTitle)
            }
        }
        selectedTopicKeys = selectedKeys
        topicsRaw = manualTitles.joined(separator: "\n")
        didConfigureExistingTopics = true
    }

    func resetTopicsForSubjectChange() {
        selectedTopicKeys = []
        topicsRaw = ""
        originalTopicTitles = []
        didConfigureExistingTopics = true
    }

    func isSelected(_ topic: String) -> Bool {
        selectedTopicKeys.contains(normalized(topic))
    }

    func toggleTopic(_ topic: String) {
        let key = normalized(topic)
        if selectedTopicKeys.contains(key) {
            selectedTopicKeys.remove(key)
        } else {
            selectedTopicKeys.insert(key)
        }
    }

    func selectableTitles(for topic: StudyTopic) -> [String] {
        let subtopics = topic.syllabusSubtopics
        return subtopics.isEmpty ? [topic.title] : subtopics.map(\.displayTitle)
    }

    func isUnitFullySelected(_ topic: StudyTopic) -> Bool {
        let titles = selectableTitles(for: topic)
        return !titles.isEmpty && titles.allSatisfy { isSelected($0) }
    }

    func isUnitPartiallySelected(_ topic: StudyTopic) -> Bool {
        let titles = selectableTitles(for: topic)
        let selectedCount = titles.filter { isSelected($0) }.count
        return selectedCount > 0 && selectedCount < titles.count
    }

    func toggleUnit(_ topic: StudyTopic) {
        let keys = selectableTitles(for: topic).map { normalized($0) }
        if keys.allSatisfy(selectedTopicKeys.contains) {
            selectedTopicKeys.subtract(keys)
        } else {
            selectedTopicKeys.formUnion(keys)
        }
    }

    func topicTitles(for subject: AcademicSubject) -> [String] {
        let selected = selectableTopicTitles(for: subject).filter {
            selectedTopicKeys.contains(normalized($0))
        }
        let manual = parsedManualTopics
        var seen: Set<String> = []
        return (selected + manual).filter { seen.insert(normalized($0)).inserted }
    }

    func topicsForGeneratedPlan(subject: AcademicSubject) -> [StudyTopic] {
        let finalTitles = topicTitles(for: subject)
        let storedTopics = subject.syllabusStudyTopics
        let minutesPerTopic = max(20, preparationMinutes / max(1, finalTitles.count))
        return finalTitles.flatMap { title -> [StudyTopic] in
            if var stored = storedTopics.first(where: { normalized($0.title) == normalized(title) }) {
                let subtopics = stored.syllabusSubtopics
                if !subtopics.isEmpty {
                    return subtopics.map { studyTopic(for: $0, parent: stored, subject: subject, minutes: minutesPerTopic) }
                }
                stored.title = title
                stored.suggestedMinutes = max(20, min(90, stored.suggestedMinutes))
                return [stored]
            }
            for parent in storedTopics {
                if let subtopic = parent.syllabusSubtopics.first(where: {
                    normalized($0.displayTitle) == normalized(title)
                }) {
                    return [studyTopic(for: subtopic, parent: parent, subject: subject, minutes: minutesPerTopic)]
                }
            }
            return [StudyTopic(
                title: title,
                summary: "Tema incluido en el examen de \(subject.name).",
                keyPoints: [],
                sourcePages: [],
                importance: 2,
                suggestedMinutes: minutesPerTopic,
                taskID: nil
            )]
        }
    }

    private func studyTopic(
        for subtopic: StudySubtopic,
        parent: StudyTopic,
        subject: AcademicSubject,
        minutes: Int
    ) -> StudyTopic {
        StudyTopic(
            title: subtopic.displayTitle,
            summary: "Subtema de \(parent.title) incluido en el examen de \(subject.name).",
            keyPoints: [subtopic.displayTitle],
            sourcePages: subtopic.sourcePages.isEmpty ? parent.sourcePages : subtopic.sourcePages,
            importance: parent.importance,
            suggestedMinutes: min(90, minutes),
            taskID: nil,
            subtopics: [subtopic]
        )
    }

    private func selectableTopicTitles(for subject: AcademicSubject) -> [String] {
        subject.syllabusStudyTopics.flatMap { selectableTitles(for: $0) }
    }

    private var parsedManualTopics: [String] {
        topicsRaw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalized(_ value: String) -> String {
        Self.normalizedValue(value)
    }

    private static func normalizedValue(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class TodayContextViewModel {
    var customMinutes = 120
    var customTimePresented = false
    var editorPresented = false

    func todayContext(from contexts: [DailyPlanningContext], calendar: Calendar = .current) -> DailyPlanningContext? {
        contexts.first { calendar.isDateInToday($0.day) }
    }
}
