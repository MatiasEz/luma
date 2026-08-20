import SwiftData
import SwiftUI

struct BalanceView: View {
    @Query private var tasks: [LumaTask]

    private var activeTasks: [LumaTask] { tasks.filter { !$0.isCompleted } }
    private var maximumMinutes: Double {
        Double(max(1, LifeArea.allCases.map(minutes(for:)).max() ?? 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionTitle(
                    eyebrow: "Balance de vida",
                    title: "Que ninguna parte tuya desaparezca",
                    trailing: "Basado en tus pendientes"
                )

                insightCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(LifeArea.allCases) { area in
                        areaCard(area)
                    }
                }

                Text("Luma usa este balance como una señal, no como una obligación. Una semana desigual puede ser exactamente lo que necesitás.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .padding(.horizontal, 4)
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Balance")
    }

    private var insightCard: some View {
        let overloaded = LifeArea.allCases.max(by: { minutes(for: $0) < minutes(for: $1) })
        let neglected = LifeArea.allCases.min(by: { minutes(for: $0) < minutes(for: $1) })

        return HStack(spacing: 18) {
            Image(systemName: "leaf.fill")
                .font(.title)
                .foregroundStyle(LumaPalette.sage)
                .frame(width: 56, height: 56)
                .background(LumaPalette.sage.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text("Lectura tranquila")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LumaPalette.sage)
                if let overloaded, let neglected, minutes(for: overloaded) > 0 {
                    Text("\(overloaded.title) concentra más carga. \(neglected.title) tiene más aire; no hace falta llenarlo, pero conviene protegerlo.")
                        .font(.body)
                        .foregroundStyle(LumaPalette.ink)
                } else {
                    Text("Todavía no hay suficiente información. El balance va a aparecer a medida que agregues pendientes.")
                        .font(.body)
                        .foregroundStyle(LumaPalette.ink)
                }
            }
            Spacer()
        }
        .lumaCard()
    }

    private func areaCard(_ area: LifeArea) -> some View {
        let areaTasks = activeTasks.filter { $0.area == area }
        let total = minutes(for: area)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: area.symbol)
                    .font(.title3)
                    .foregroundStyle(area.color)
                    .frame(width: 38, height: 38)
                    .background(area.color.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(area.title)
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text("\(areaTasks.count) tareas · \(formattedMinutes(total))")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(area.color.opacity(0.1))
                    Capsule().fill(area.color)
                        .frame(width: proxy.size.width * CGFloat(Double(total) / maximumMinutes))
                }
            }
            .frame(height: 8)

            Text(areaMessage(area, minutes: total))
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .lumaCard(padding: 16)
    }

    private func minutes(for area: LifeArea) -> Int {
        activeTasks.filter { $0.area == area }.reduce(0) { $0 + $1.estimatedMinutes }
    }

    private func formattedMinutes(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    private func areaMessage(_ area: LifeArea, minutes: Int) -> String {
        if minutes == 0 {
            return area == .rest ? "Hay espacio para descanso real." : "Sin carga visible esta semana."
        }
        if Double(minutes) / maximumMinutes > 0.8 {
            return "Esta área está llevando bastante peso."
        }
        return "Carga manejable por ahora."
    }
}
