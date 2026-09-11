import Foundation
import Observation

@MainActor
@Observable
final class FocusRoomViewModel {
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var sessionID = UUID()
    var plannedBlockID: UUID?
    @ObservationIgnored private var checkpointAt = Date.now
    @ObservationIgnored private var fractionalElapsedSeconds = 0.0
    static let persistenceKey = "lumaActiveFocus.v1"

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.persistenceKey),
           let saved = try? JSONDecoder().decode(ActiveFocusSnapshot.self, from: data),
           (1...1440).contains(saved.durationMinutes), !saved.completed {
            sessionID = saved.id
            plannedBlockID = saved.plannedBlockID
            selectedTaskID = saved.taskID
            durationMinutes = saved.durationMinutes
            elapsedSeconds = saved.elapsed(at: now)
            remainingSeconds = max(0, durationMinutes * 60 - elapsedSeconds)
            isRunning = saved.isRunning
            sessionStartedAt = saved.startedAt
        }
        checkpointAt = now
    }

    func checkpoint(now: Date = .now, advance: Bool = false) {
        if advance, isRunning {
            let additional = fractionalElapsedSeconds + max(0, now.timeIntervalSince(checkpointAt))
            let wholeSeconds = Int(floor(additional + 0.000001))
            fractionalElapsedSeconds = max(0, additional - Double(wholeSeconds))
            elapsedSeconds = min(durationMinutes * 60, elapsedSeconds + wholeSeconds)
            remainingSeconds = max(0, durationMinutes * 60 - elapsedSeconds)
        }
        checkpointAt = now
        let snapshot = ActiveFocusSnapshot(id: sessionID, taskID: selectedTaskID,
            durationMinutes: durationMinutes, elapsedSeconds: elapsedSeconds, isRunning: isRunning,
            startedAt: sessionStartedAt, checkpointAt: now, completed: completedSession, plannedBlockID: plannedBlockID)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.persistenceKey) }
    }

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
        if let selectedTaskID { return tasks.first { $0.id == selectedTaskID } }
        return pendingTasks(from: tasks).first
    }

    var timeString: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var durationOptions: [Int] {
        Array(Set([15, 25, 45, 60, durationMinutes])).sorted()
    }

    func reset() {
        guard elapsedSeconds == 0 || completedSession else { return }
        sessionID = UUID()
        plannedBlockID = nil
        isRunning = false
        ambientAudio.stop()
        completedSession = false
        elapsedSeconds = 0
        fractionalElapsedSeconds = 0
        lastRecordedMinutes = 0
        sessionStartedAt = nil
        recordedSession = nil
        remainingSeconds = durationMinutes * 60
        checkpoint()
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

    func activeSubjects(from subjects: [AcademicSubject]) -> [AcademicSubject] {
        subjects.filter { !$0.isArchived }
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
