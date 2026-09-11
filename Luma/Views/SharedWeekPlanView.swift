import SwiftUI

struct SharedWeekPlanView: View {
    @Environment(AppState.self) private var appState
    let days: [Date]
    let tasks: [LumaTask]
    var onSelect: (LumaTask, PlannedWorkBlock?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Avances de la semana").font(.headline).foregroundStyle(LumaPalette.ink)
            Text("La entrega tiene su propia fecha. Los días futuros son una propuesta según tu disponibilidad habitual; podés ajustarlos.")
                .font(.caption).foregroundStyle(LumaPalette.secondaryInk)
            if !appState.sharedPlan.capacityIssues.isEmpty {
                let missing = appState.sharedPlan.capacityIssues.reduce(0) { $0 + $1.missingMinutes }
                Label("Faltan aproximadamente \(missing) min para dejar todo listo antes del día de entrega. Revisá el alcance, las fechas o el tiempo disponible.", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(LumaPalette.terracotta)
                ForEach(appState.sharedPlan.capacityIssues.prefix(3)) { issue in
                    if let task = tasks.first(where: { $0.id == issue.taskID }) {
                        Button("\(task.title) · faltan \(issue.missingMinutes) min") { onSelect(task, nil) }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(LumaPalette.indigo)
                    }
                }
            }
            ForEach(appState.sharedPlan.schedulingWarnings ?? [], id: \.self) { warning in
                Label(warning, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(LumaPalette.terracotta)
            }
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(days, id: \.self) { day in
                        let blocks = appState.workBlocks(on: day)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "es_AR")))).font(.subheadline.bold())
                            Text("\(blocks.filter { $0.status != .completed }.reduce(0) { $0 + $1.minutes }) min de trabajo")
                                .font(.caption2).foregroundStyle(LumaPalette.secondaryInk)
                            if blocks.isEmpty { Text("Sin bloques previstos").font(.caption).foregroundStyle(LumaPalette.secondaryInk) }
                            ForEach(blocks) { block in
                                if let task = tasks.first(where: { $0.id == block.taskID }) {
                                    Button { onSelect(task, block) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(task.title).font(.caption.weight(.medium)).lineLimit(2)
                                            Text("\(block.minutes) min · \(block.status.title)").font(.caption2)
                                            if let start = block.startMinute { Text(String(format: "%02d:%02d", start / 60, start % 60)).font(.caption2.monospacedDigit()) }
                                        }
                                        .foregroundStyle(block.status == .completed ? LumaPalette.sage : LumaPalette.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(9).background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(width: 160, alignment: .leading).id(day)
                    }
                }.padding(.bottom, 5)
            }
            .onAppear { if let day = days.first(where: { Calendar.current.isDateInToday($0) }) { proxy.scrollTo(day, anchor: .leading) } }
            .onChange(of: days) { _, updated in if let day = updated.first(where: { Calendar.current.isDateInToday($0) }) { proxy.scrollTo(day, anchor: .leading) } }
            }
        }.padding(18).background(LumaPalette.indigo.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
    }
}
