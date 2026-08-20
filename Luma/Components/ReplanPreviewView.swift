import SwiftUI

struct ReplanPreviewView: View {
    let proposal: ReplanProposal
    let tasks: [LumaTask]
    let onCancel: () -> Void
    let onApply: () -> Void

    private let scheduler = DailyScheduler()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(LumaPalette.indigo)
                VStack(alignment: .leading, spacing: 5) {
                    Text(proposal.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text(proposal.explanation)
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Text(proposal.source.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.sage)
            }

            HStack(alignment: .top, spacing: 14) {
                planColumn(
                    title: "Ahora",
                    energy: proposal.beforeEnergy,
                    availableMinutes: proposal.beforeAvailableMinutes,
                    taskIDs: proposal.beforeTaskIDs,
                    blocks: proposal.beforeBlocks,
                    color: LumaPalette.secondaryInk
                )
                Image(systemName: "arrow.right")
                    .foregroundStyle(LumaPalette.indigo)
                    .padding(.top, 74)
                planColumn(
                    title: "Propuesta",
                    energy: proposal.afterEnergy,
                    availableMinutes: proposal.afterAvailableMinutes,
                    taskIDs: proposal.afterTaskIDs,
                    blocks: proposal.afterBlocks,
                    color: LumaPalette.indigo
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Qué cambia")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LumaPalette.indigo)
                ForEach(proposal.changeSummary, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }
            .lumaCard(padding: 14)

            HStack {
                Text("Nada se mueve hasta que confirmes.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.sage)
                Spacer()
                Button("Dejar como está", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Aplicar reacomodo", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
            }
        }
        .padding(24)
        .background(LumaBackground())
        .frame(width: 760, height: 610)
    }

    private func planColumn(
        title: String,
        energy: EnergyPreference,
        availableMinutes: Int,
        taskIDs: [UUID],
        blocks: [AgendaBlockSnapshot],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline).foregroundStyle(color)
                Spacer()
                Text(durationTitle(availableMinutes))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Text(energy.title)
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)

            ForEach(Array(taskIDs.prefix(3).enumerated()), id: \.element) { index, taskID in
                if let task = tasks.first(where: { $0.id == taskID }) {
                    let block = blocks.first(where: { $0.taskID == taskID })
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(task.area.color)
                            .frame(width: 26, height: 26)
                            .background(task.area.color.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LumaPalette.ink)
                                .lineLimit(1)
                            Text(blockTitle(block))
                                .font(.caption2)
                                .foregroundStyle(LumaPalette.secondaryInk)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .top)
        .lumaCard(padding: 16)
    }

    private func blockTitle(_ block: AgendaBlockSnapshot?) -> String {
        guard let block else { return "Sin bloque asignado" }
        let start = scheduler.date(on: proposal.day, minuteOfDay: block.startMinuteOfDay)
        return "\(start.formatted(date: .omitted, time: .shortened)) · \(block.durationMinutes) min"
    }

    private func durationTitle(_ minutes: Int) -> String {
        if minutes == 0 { return "Día protegido" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return hours == 1 ? "1 hora" : "\(hours) horas" }
        return "\(hours) h \(remainder) min"
    }
}
