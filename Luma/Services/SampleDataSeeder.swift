import Foundation
import SwiftData

@MainActor
enum SampleDataSeeder {
    private static let seedKey = "didSeedLumaMVP"

    static func seedIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seedKey) else { return }
        let calendar = Calendar.current

        let samples = [
            LumaTask(
                title: "Avanzar ensayo de ética",
                area: .university,
                deadline: calendar.date(byAdding: .day, value: 4, to: .now),
                estimatedMinutes: 90,
                energy: .high,
                impact: .grade,
                academicWeight: 25
            ),
            LumaTask(
                title: "Enviar cotización freelance",
                area: .sideHustle,
                deadline: calendar.date(byAdding: .day, value: 1, to: .now),
                estimatedMinutes: 25,
                energy: .medium,
                impact: .money,
                unlocksAnotherTask: true
            ),
            LumaTask(
                title: "Ordenar el cuarto",
                area: .home,
                deadline: calendar.date(byAdding: .day, value: 3, to: .now),
                estimatedMinutes: 20,
                energy: .low,
                impact: .wellbeing
            ),
            LumaTask(
                title: "Renovar documentación",
                area: .errands,
                deadline: calendar.date(byAdding: .day, value: 6, to: .now),
                estimatedMinutes: 35,
                energy: .medium,
                impact: .urgency,
                postponementCount: 2
            ),
            LumaTask(
                title: "Tarde libre para dibujar",
                area: .hobbies,
                deadline: calendar.date(byAdding: .day, value: 5, to: .now),
                estimatedMinutes: 45,
                energy: .low,
                impact: .wellbeing
            ),
        ]

        samples.forEach(context.insert)
        try? context.save()
        UserDefaults.standard.set(true, forKey: seedKey)
    }
}
