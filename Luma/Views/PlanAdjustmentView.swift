import SwiftData
import SwiftUI

struct PlanAdjustmentView: View {
    @Environment(AppState.self) private var appState
    let tasks: [LumaTask]
    let sessions: [FocusSession]
    let planner: TaskPlanner
    let preferredAreas: [LifeArea]
    @State private var postponedTask: LumaTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Menu("Cambiar una prioridad") {
                ForEach(appState.dailyPlan?.taskIDs ?? [], id: \.self) { id in
                    if let current = tasks.first(where: { $0.id == id }) {
                        Menu("En lugar de \(current.title)") {
                            ForEach(tasks.filter { !$0.isCompleted && $0.id != id && $0.academicSourceType != .rest && $0.planningDetails.isRetired != true }) { task in
                                Button(task.title) { _ = appState.prioritize(task, replacing: id, tasks: tasks, planner: planner) }
                            }
                        }
                    }
                }
            }.foregroundStyle(LumaPalette.indigo)
            let repeated = tasks.filter { !$0.isCompleted && $0.postponementCount >= 2 && $0.planningDetails.isRetired != true }
            if !repeated.isEmpty {
                DisclosureGroup("Algo se viene postergando · podemos ajustarlo") {
                    ForEach(repeated.prefix(3)) { task in
                        HStack {
                            Text(task.title).font(.caption)
                            Spacer()
                            Button("Qué pasó") { postponedTask = task }.buttonStyle(.borderless)
                        }.padding(.vertical, 5)
                    }
                }
            }
            if !appState.rememberedPreferences.isEmpty {
                DisclosureGroup("Lo que Luma recuerda") {
                    ForEach(appState.rememberedPreferences, id: \.self) { preference in
                        HStack { Text(preference).font(.caption); Spacer(); Button("Olvidar") { appState.rememberedPreferences.removeAll { $0 == preference } } }
                    }
                }
            }
            DisclosureGroup("Tu balance de esta semana") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Esto refleja lo que registraste en Luma. Si un área no aparece, no significa que la hayas descuidado.")
                        .font(.caption).foregroundStyle(LumaPalette.secondaryInk)
                    ForEach(LifeArea.allCases) { area in
                        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
                        let minutes = sessions.filter { $0.area == area && $0.endedAt >= weekStart }.reduce(0) { $0 + $1.actualMinutes }
                        let completed = tasks.filter { $0.area == area && $0.isCompleted && ($0.completedAt ?? .distantPast) >= weekStart }.count
                        HStack {
                            Label(area.title, systemImage: area.symbol)
                            if preferredAreas.contains(area) { Text("Elegida por vos").font(.caption2).foregroundStyle(LumaPalette.sage) }
                            Spacer()
                            Text(minutes == 0 && completed == 0 ? "Sin registro" : "\(minutes) min · \(completed) hechas")
                        }.font(.caption)
                    }
                }.padding(.top, 10)
            }
        }
        .font(.subheadline).foregroundStyle(LumaPalette.ink)
        .sheet(item: $postponedTask) { task in PostponementEditor(task: task) }
    }
}

struct PostponementEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let task: LumaTask
    @State private var reason = PostponementReason.time
    @State private var nextStep = ""
    @State private var estimate = 30
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Busquemos una forma más fácil").font(.title2.weight(.semibold))
            Text(task.title).foregroundStyle(LumaPalette.secondaryInk)
            Picker("Qué pasó", selection: $reason) { ForEach(PostponementReason.allCases) { Text($0.title).tag($0) } }
            if reason == .unclear {
                TextField("Primer paso concreto · por ejemplo, abrir el archivo y escribir tres ideas", text: $nextStep, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Text("Podemos empezar por un bloque de 15 minutos.").font(.caption)
            }
            if reason == .time { Stepper("Creo que todavía faltan \(estimate) min", value: $estimate, in: 5...1800, step: 5) }
            if reason == .waiting { Text("La dejamos en espera hasta que la retomes. La fecha de entrega sigue visible.").font(.caption) }
            if let errorMessage { Text(errorMessage).foregroundStyle(LumaPalette.terracotta) }
            HStack {
                Button("Ahora no") { dismiss() }
                Spacer()
                if task.planningDetails.postponementReason == .waiting {
                    Button("Ya puedo retomarla") { save(resume: true) }
                }
                Button("Guardar ajuste") { save(resume: false) }.buttonStyle(.borderedProminent).tint(LumaPalette.indigo)
            }
        }.padding(28).frame(width: 520).background(LumaBackground())
        .onAppear { estimate = task.remainingEstimatedMinutes; reason = task.planningDetails.postponementReason ?? .time; nextStep = task.planningDetails.nextStep ?? "" }
    }

    private func save(resume: Bool) {
        let previous = task.planningDetails
        let oldEstimate = task.estimatedMinutes
        var details = previous
        details.postponementReason = resume ? nil : reason
        details.deferredUntil = !resume && (reason == .time || reason == .energy) ? Calendar.current.date(byAdding: .day, value: 1, to: .now) : nil
        details.nextStep = nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : nextStep
        if reason == .time && !resume { task.estimatedMinutes = task.focusedMinutes + estimate }
        task.planningDetails = details
        task.touch()
        do { try modelContext.save(); appState.refreshPlan(); dismiss() }
        catch { task.planningDetails = previous; task.estimatedMinutes = oldEstimate; errorMessage = "No pude guardar el ajuste. Podés reintentarlo." }
    }
}
