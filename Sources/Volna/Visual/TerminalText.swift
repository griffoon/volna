import SwiftUI

/// Text that "decrypts" from noise glyphs into its value whenever the value changes.
struct ScrambleText: View {
    let text: String
    var duration: Double = 0.5
    @State private var shown = ""

    private static let noise = Array("▓▒░#@%&$*/\\<>01")
    private static let frame: Duration = .milliseconds(33)

    var body: some View {
        Text(shown.isEmpty ? text : shown)
            .task(id: text) {
                let chars = Array(text)
                let steps = max(1, Int(duration / 0.033))
                for step in 0...steps {
                    let fixed = chars.count * step / steps
                    shown = String(chars.enumerated().map { i, c in
                        i < fixed || c == " " ? c : Self.noise.randomElement()!
                    })
                    try? await Task.sleep(for: Self.frame)
                    if Task.isCancelled { return }
                }
                shown = text
            }
    }
}

/// `▁▂▃▅▇` bars driven by the live analyzer.
struct SpectrumText: View {
    var isPlaying: Bool
    /// How many of the analyzer bands to show, from the bass up.
    var bars = AudioAnalyzer.bandCount
    private static let ramp = Array("▁▂▃▄▅▆▇█")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isPlaying)) { _ in
            let levels = AudioAnalyzer.shared.snapshot()
            let live = isPlaying && Date().timeIntervalSince(levels.updated) < 0.5
            Text(String(levels.bands.prefix(bars).map { level in
                Self.ramp[min(7, Int((live ? level : 0) * 8))]
            }))
            .font(Brand.mono(13, weight: .bold))
            .foregroundStyle(Brand.acid)
            .kerning(1.5)
            .fixedSize()
        }
        .accessibilityHidden(true)
    }
}
