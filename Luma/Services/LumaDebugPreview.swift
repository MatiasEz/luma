import Foundation
import SwiftData

enum LumaDebugPreview {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--luma-preview")
        #else
        false
        #endif
    }

    static var defaults: UserDefaults {
        isEnabled ? UserDefaults(suiteName: "com.luma.preview.v08")! : .standard
    }

    @MainActor
    static func seed(_ context: ModelContext) throws {
        guard isEnabled, try context.fetchCount(FetchDescriptor<LumaTask>()) == 0 else { return }
        defaults.set(true, forKey: "lumaOnboardingCompleted")
        let subject = AcademicSubject(name: "Historia", colorHex: "#59639A", syllabusRaw: "Sociedad y cultura\nCambios políticos\nRepaso de fuentes")
        context.insert(subject)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        context.insert(LumaTask(title: "Preparar la entrega de Historia", area: .university, dueDate: tomorrow,
            estimatedMinutes: 90, impact: .grade, academicWeight: 30, academicSubjectID: subject.id))
        context.insert(LumaTask(title: "Enviar cotización de diseño", area: .sideHustle, dueDate: .now.addingTimeInterval(4 * 86400), estimatedMinutes: 30, energy: .low, impact: .money))
        context.insert(LumaTask(title: "Ordenar el escritorio", area: .home, estimatedMinutes: 15, energy: .low, impact: .wellbeing))
        let exam = AcademicExam(title: "Parcial de Historia", subjectID: subject.id, date: .now.addingTimeInterval(12 * 86400))
        context.insert(exam)
        context.insert(LumaProfile())
        context.insert(DailyPlanningContext(day: .now, availableMinutes: 150))
        try context.save()
    }
}
