import SwiftUI

struct AIDownloadProgressView: View {
    @Environment(LocalAIEngine.self) private var aiEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(LumaPalette.indigo)
                Text("Preparando \(aiEngine.activeModel?.title ?? "Luma")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
                if aiEngine.hasMeasuredDownload {
                    Text(aiEngine.downloadProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(LumaPalette.indigo)
                } else {
                    Text("Conectando…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }

            if aiEngine.hasMeasuredDownload {
                ProgressView(value: aiEngine.downloadProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(LumaPalette.indigo)
                    .accessibilityLabel("Progreso de descarga")
                    .accessibilityValue(
                        Text(aiEngine.downloadProgress, format: .percent.precision(.fractionLength(0)))
                    )
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(LumaPalette.indigo)
                    .accessibilityLabel("Conectando para iniciar la descarga")
            }

            HStack {
                Text(aiEngine.downloadDetailTitle)
                    .monospacedDigit()
                Spacer()
                Text("Podés seguir usando Luma")
            }
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)
        }
    }
}
