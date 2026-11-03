import SwiftUI

/// «Голос» slider under the player: how much of the singer to keep, 100 % = original.
struct VocalSlider: View {
    @State private var separator = VocalSeparator.shared
    /// Slider steps that get a haptic tick.
    private static let step = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "mic.slash").font(.system(size: 13, weight: .semibold))
                Slider(value: $separator.level, in: 0...1)
                    .tint(Brand.acid)
                    .onChange(of: (separator.level / Self.step).rounded()) { Haptics.tick() }
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7))

            HStack {
                Text(status)
                Spacer()
                Text("голос \(Int((separator.level * 100).rounded()))%")
            }
            .font(Brand.mono(11, weight: .medium))
            .foregroundStyle(statusColor)
            .contentTransition(.numericText())
        }
    }

    private var status: String {
        switch separator.phase {
        case .idle: separator.isActive ? "> жду трек" : "> двигай влево, чтобы убрать голос"
        case .preparing: "> загружаю модель…"
        case .working(let progress): "> отделяю голос… \(Int(progress * 100))%"
        case .ready: "> голос отделён"
        case .failed(let message): "> ошибка: \(message)"
        }
    }

    private var statusColor: Color {
        if case .failed = separator.phase { return Color(red: 1, green: 0.45, blue: 0.45) }
        return Brand.acid.opacity(0.85)
    }
}
