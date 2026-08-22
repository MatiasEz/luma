import Foundation
import Observation

@MainActor
@Observable
final class FocusRoomViewModel {
    var selectedTaskID: UUID?
    var durationMinutes = 25
    var remainingSeconds = 25 * 60
    var isRunning = false
    var completedSession = false
    var elapsedSeconds = 0
    var lastRecordedMinutes = 0
    var sessionStartedAt: Date?
    var recordedSession: FocusSession?
    let ambientAudio = FocusAmbientAudioPlayer()

    func pendingTasks(from tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { !$0.isCompleted && !TaskDependencyResolver.isBlocked($0, in: tasks) }
    }

    func selectedTask(from tasks: [LumaTask]) -> LumaTask? {
        let pending = pendingTasks(from: tasks)
        return pending.first { $0.id == selectedTaskID } ?? pending.first
    }

    var timeString: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var durationOptions: [Int] {
        Array(Set([15, 25, 45, 60, durationMinutes])).sorted()
    }

    func reset() {
        isRunning = false
        ambientAudio.stop()
        completedSession = false
        elapsedSeconds = 0
        lastRecordedMinutes = 0
        sessionStartedAt = nil
        recordedSession = nil
        remainingSeconds = durationMinutes * 60
    }
}

@MainActor
@Observable
final class InsightsViewModel {
    var aiSummary: String?
    var deleteConfirmationPresented = false
    var ignoreWeekConfirmationPresented = false

    private let engine = BehaviorLearningEngine()

    func profile(from sessions: [FocusSession]) -> UserRhythmProfile {
        engine.profile(from: sessions)
    }

    func weeklySummary(for profile: UserRhythmProfile) -> String {
        engine.weeklySummary(for: profile)
    }
}

@MainActor
@Observable
final class OnboardingViewModel {
    var step = 0
    var selectedAreas: Set<LifeArea> = [.university, .home, .rest]
    var energyPeak: EnergyPeak = .afternoon
    var loadedProfile = false

    func load(profile: LumaProfile?) {
        guard !loadedProfile else { return }
        if let profile {
            selectedAreas = Set(profile.selectedAreas)
            energyPeak = profile.energyPeak
        }
        loadedProfile = true
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    var backupDocument = LumaBackupDocument()
    var isExporting = false
    var isImporting = false
    var backupMessage = ""
}

@MainActor
@Observable
final class LumaAssistantViewModel {
    var draft = ""
    var isSending = false
    var errorMessage = ""
    var confirmingRecordID: UUID?
    var replanProposal: ReplanProposal?
    var replanRecordID: UUID?

    func confirmationRecord(in messages: [LumaChatRecord]) -> LumaChatRecord? {
        guard let confirmingRecordID else { return nil }
        return messages.first { $0.id == confirmingRecordID }
    }
}

@MainActor
@Observable
final class SubjectsViewModel {
    var editorPresented = false
    var editingSubject: AcademicSubject?
    var subjectToArchive: AcademicSubject?
    var gradeDetailSubject: AcademicSubject?
    var quickGradeEntryPresented = false

    func activeSubjects(from subjects: [AcademicSubject]) -> [AcademicSubject] {
        subjects.filter { !$0.isArchived }
    }

    func activeItems(from items: [SubjectGradeItem]) -> [SubjectGradeItem] {
        items.filter { !$0.isArchived }
    }

    func gradeEntryTasks(
        subjects: [AcademicSubject],
        items: [SubjectGradeItem],
        tasks: [LumaTask]
    ) -> [LumaTask] {
        let subjectIDs = Set(activeSubjects(from: subjects).map(\.id))
        let itemIDs = Set(activeItems(from: items).map(\.id))
        return tasks.filter {
            $0.academicSubjectID.map(subjectIDs.contains) == true
                && $0.subjectGradeItemID.map(itemIDs.contains) == true
                && ($0.isCompleted || $0.grade != nil)
        }
    }
}

@MainActor
@Observable
final class StudyModeViewModel {
    var selectedGuideID: UUID?
    var examDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    var isFileImporterPresented = false
    var isProcessing = false
    var processingProgress = 0.0
    var processingStage = ""
    var message = ""
    var selectedTab = StudyDetailTab.plan
    var cardIndex = 0
    var isCardRevealed = false
    var questionIndex = 0
    var selectedAnswer: Int?

    func selectedGuide(from guides: [StudyGuide]) -> StudyGuide? {
        guides.first { $0.id == selectedGuideID } ?? guides.first
    }

    func resetPracticeState() {
        selectedTab = .plan
        cardIndex = 0
        isCardRevealed = false
        questionIndex = 0
        selectedAnswer = nil
    }
}
