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

            if separator.isActive {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(diagnostics)
                        .font(Brand.mono(10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    /// Numbers to report when something sounds wrong: separation speed (×, below 1 can't keep
    /// up), decoder offset in samples, how well it matched (0…1) and read-position jumps.
    private var diagnostics: String {
        guard let stem = VocalStems.stem else { return "> диагностика: —" }
        let info = stem.alignmentInfo
        let speed = stem.speed > 0 ? String(format: "x%.1f", stem.speed) : "x—"
        let offset = info.offset.map { "\($0)" } ?? "ищу"
        return "> \(speed) | сдвиг \(offset) | совп \(String(format: "%.2f", info.score)) | скачков \(info.resyncs)"
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
