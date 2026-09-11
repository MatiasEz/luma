import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class QuickCaptureViewModel {
    #if DEBUG
    private static let interpretationLog = Logger(
        subsystem: "com.luma.organizer",
        category: "AIInterpretation"
    )
    #endif

    var draft = ParsedTaskDraft()
    var naturalLanguageInput = ""
    var academicDrafts: [AcademicCaptureDraft] = []
    var interpretationNotice: String?
    var clarification: AcademicCaptureClarification?
    var originalRequest = ""
    var isInterpreting = false

    var hasInterpretation: Bool {
        !academicDrafts.isEmpty || interpretationNotice != nil || clarification != nil
    }

    var isAwaitingClarification: Bool {
        clarification != nil
    }

    func interpret(
        subjects: [AcademicSubject],
        aiEngine: LocalAIEngine,
        now: Date = .now
    ) async {
        let input = naturalLanguageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isInterpreting else { return }

        #if DEBUG
        Self.interpretationLog.notice("🧭 [FLOW] Recibido: \(input, privacy: .public)")
        #endif

        isInterpreting = true
        interpretationNotice = nil
        defer { isInterpreting = false }

        if let pending = clarification,
           academicDrafts.contains(where: { $0.id == pending.draftID })
        {
            await continueInterpretation(
                answer: input,
                clarification: pending,
                subjects: subjects,
                aiEngine: aiEngine,
                now: now
            )
            return
        }

        originalRequest = input
        let parser = AcademicCaptureParser()
        let explicitDrafts = parser.parseMany(input, subjects: subjects, now: now)
        #if DEBUG
        let localSummary = explicitDrafts.enumerated().map { index, draft in
            "#\(index + 1) \(self.debugSummary(draft, subjects: subjects))"
        }.joined(separator: "\n")
        Self.interpretationLog.debug("🧩 [LOCAL PARSER] \(explicitDrafts.count) propuesta(s)\n\(localSummary, privacy: .public)")
        #endif
        guard aiEngine.isInstalled || aiEngine.isStudyModelInstalled else {
            #if DEBUG
            Self.interpretationLog.warning("⚠️ [FALLBACK] Modelo no instalado; se usa el parser local")
            #endif
            accept(drafts: explicitDrafts, notice: nil, subjects: subjects)
            return
        }

        do {
            let result = try await aiEngine.interpretAcademicCapture(input, subjects: subjects, now: now)
            let reinforced = AcademicCaptureInterpretationValidator.reinforcingExplicitSignals(
                in: result,
                with: explicitDrafts
            )
            accept(drafts: reinforced.drafts, notice: reinforced.notice, subjects: subjects)
        } catch {
            #if DEBUG
            Self.interpretationLog.error("❌ [FALLBACK] DeepSeek falló: \(String(describing: error), privacy: .public). Se conserva el parser local")
            #endif
            aiEngine.clearFailure()
            accept(drafts: explicitDrafts, notice: nil, subjects: subjects)
        }
    }

    func resetInterpretation() {
        if !originalRequest.isEmpty {
            naturalLanguageInput = originalRequest
        }
        academicDrafts = []
        interpretationNotice = nil
        clarification = nil
        originalRequest = ""
    }

    func removeDraft(id: UUID, subjects: [AcademicSubject]) {
        academicDrafts.removeAll { $0.id == id }
        clarification = AcademicCaptureClarificationEngine.next(in: academicDrafts, subjects: subjects)
    }

    private func continueInterpretation(
        answer: String,
        clarification pending: AcademicCaptureClarification,
        subjects: [AcademicSubject],
        aiEngine: LocalAIEngine,
        now: Date
    ) async {
        guard let existing = academicDrafts.first(where: { $0.id == pending.draftID }) else {
            #if DEBUG
            Self.interpretationLog.error("❌ [FLOW] El borrador solicitado ya no existe: \(pending.draftID.uuidString, privacy: .public)")
            #endif
            clarification = AcademicCaptureClarificationEngine.next(in: academicDrafts, subjects: subjects)
            return
        }
        #if DEBUG
        Self.interpretationLog.notice("↪️ [ANSWER] field=\(pending.field.rawValue, privacy: .public) | answer=\(answer, privacy: .public)")
        #endif
        var resolved = academicDrafts

        AcademicCaptureClarificationEngine.apply(
            answer: answer,
            to: pending,
            drafts: &resolved,
            subjects: subjects,
            now: now
        )

        if pending.field != .subjectConfirmation,
           (aiEngine.isInstalled || aiEngine.isStudyModelInstalled)
        {
            let continuation = AcademicCaptureContinuation(
                originalRequest: originalRequest,
                draft: existing,
                requestedField: pending.field,
                question: pending.question
            )
            do {
                let result = try await aiEngine.interpretAcademicCapture(
                    answer,
                    subjects: subjects,
                    now: now,
                    continuation: continuation
                )
                if let interpreted = result.drafts.first,
                   let resolvedIndex = resolved.firstIndex(where: { $0.id == pending.draftID })
                {
                    resolved[resolvedIndex] = AcademicCaptureClarificationEngine.merge(
                        interpreted,
                        into: resolved[resolvedIndex],
                        resolving: pending.field
                    )
                }
                interpretationNotice = result.notice
            } catch {
                #if DEBUG
                Self.interpretationLog.error("❌ [CONTINUATION FALLBACK] DeepSeek falló: \(String(describing: error), privacy: .public). Se usa la respuesta interpretada localmente")
                #endif
                aiEngine.clearFailure()
            }
        }

        accept(drafts: resolved, notice: interpretationNotice, subjects: subjects)
    }

    private func accept(
        drafts: [AcademicCaptureDraft],
        notice: String?,
        subjects: [AcademicSubject]
    ) {
        academicDrafts = drafts
        interpretationNotice = notice
        clarification = AcademicCaptureClarificationEngine.next(in: drafts, subjects: subjects)
        naturalLanguageInput = clarification == nil ? originalRequest : ""

        #if DEBUG
        let summary = drafts.enumerated().map { index, draft in
            "#\(index + 1) \(self.debugSummary(draft, subjects: subjects))"
        }.joined(separator: "\n")
        Self.interpretationLog.notice("📝 [FINAL DRAFT]\n\(summary.isEmpty ? "Sin propuestas" : summary, privacy: .public)")
        if let clarification {
            Self.interpretationLog.notice("❓ [MISSING] field=\(clarification.field.rawValue, privacy: .public) | question=\(clarification.question, privacy: .public)")
        } else {
            Self.interpretationLog.notice("🏁 [READY] La propuesta está lista para confirmar")
        }
        #endif
    }

    #if DEBUG
    private func debugSummary(
        _ draft: AcademicCaptureDraft,
        subjects: [AcademicSubject]
    ) -> String {
        let subject = draft.subjectID.flatMap { id in subjects.first { $0.id == id }?.name }
            ?? draft.proposedSubjectName
            ?? "sin materia"
        let date = draft.date?.formatted(date: .numeric, time: .shortened) ?? "sin fecha"
        let weekday = draft.weekday.map(String.init) ?? "sin recurrencia"
        let time = draft.minuteOfDay.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "sin hora"
        return "id=\(draft.id.uuidString.prefix(8)) | kind=\(draft.kind.rawValue) | title=\(draft.title) | subject=\(subject) | date=\(date) | weekday=\(weekday) | time=\(time) | duration=\(draft.estimatedMinutes)m"
    }
    #endif

    func activeSubjects(from subjects: [AcademicSubject]) -> [AcademicSubject] {
        subjects.filter { !$0.isArchived }
    }

    func assignmentIsValid(subjects: [AcademicSubject]) -> Bool {
        guard draft.area == .university else { return true }
        guard let subjectID = draft.academicSubjectID else { return true }
        return activeSubjects(from: subjects).contains { $0.id == subjectID }
    }

    func canSave(subjects: [AcademicSubject]) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assignmentIsValid(subjects: subjects)
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
    var dueDate: Date?
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
        dueDate = task.dueDate
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

    func assignmentIsValid(subjects: [AcademicSubject]) -> Bool {
        guard area == .university else { return true }
        guard let academicSubjectID else { return true }
        return availableSubjects(from: subjects).contains { $0.id == academicSubjectID }
    }

    func canSave(subjects: [AcademicSubject]) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assignmentIsValid(subjects: subjects)
    }

    func apply(to task: LumaTask) {
        task.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.area = area
        task.dueDate = dueDate
        task.deadline = deadline
        task.estimatedMinutes = estimatedMinutes
        task.energy = energy
        task.impact = impact
        task.academicWeight = nil
        task.academicSubjectID = area == .university ? academicSubjectID : nil
        task.subjectGradeItemID = nil
        task.grade = nil
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
