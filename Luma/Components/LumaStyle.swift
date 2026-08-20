import SwiftUI

enum LumaPalette {
    static let canvas = Color(red: 0.965, green: 0.944, blue: 0.905)
    static let canvasDeep = Color(red: 0.910, green: 0.891, blue: 0.858)
    static let ink = Color(red: 0.165, green: 0.175, blue: 0.245)
    static let secondaryInk = Color(red: 0.390, green: 0.396, blue: 0.455)
    static let indigo = Color(red: 0.310, green: 0.340, blue: 0.520)
    static let sage = Color(red: 0.430, green: 0.590, blue: 0.500)
    static let terracotta = Color(red: 0.810, green: 0.490, blue: 0.380)
    static let mustard = Color(red: 0.850, green: 0.650, blue: 0.300)
    static let lavender = Color(red: 0.590, green: 0.530, blue: 0.720)
    static let rose = Color(red: 0.820, green: 0.520, blue: 0.590)
    static let card = Color.white.opacity(0.72)
}

struct LumaBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [LumaPalette.canvas, LumaPalette.canvasDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(LumaPalette.lavender.opacity(0.12))
                .frame(width: 480, height: 480)
                .blur(radius: 4)
                .offset(x: 360, y: -280)

            Circle()
                .fill(LumaPalette.sage.opacity(0.11))
                .frame(width: 360, height: 360)
                .offset(x: -420, y: 320)
        }
        .ignoresSafeArea()
    }
}

struct LumaCardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(LumaPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: LumaPalette.ink.opacity(0.055), radius: 18, y: 8)
    }
}

extension View {
    func lumaCard(padding: CGFloat = 18) -> some View {
        modifier(LumaCardModifier(padding: padding))
    }
}

struct AreaPill: View {
    let area: LifeArea

    var body: some View {
        Label(area.title, systemImage: area.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(area.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(area.color.opacity(0.12), in: Capsule())
    }
}

struct SoftButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(color)
            .background(color.opacity(configuration.isPressed ? 0.18 : 0.11), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SectionTitle: View {
    let eyebrow: String
    let title: String
    var trailing: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) {
                titleBlock
                Spacer(minLength: 12)
                if let trailing { trailingLabel(trailing) }
            }

            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                if let trailing { trailingLabel(trailing) }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(LumaPalette.sage)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trailingLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(LumaPalette.sage)
            Text(title)
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(LumaPalette.secondaryInk)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .lumaCard()
    }
}
