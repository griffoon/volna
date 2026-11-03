import SwiftUI

/// The cover gives a small push on every kick drum, timed to the audible kick.
struct KickBounce: ViewModifier {
    static let storageKey = "coverBounce"
    @AppStorage(KickBounce.storageKey) private var enabled = true
    let isPlaying: Bool
    /// Extra scale at the moment of a full-strength kick.
    var amount: CGFloat = 0.035

    func body(content: Content) -> some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !isPlaying)) { _ in
                content.scaleEffect(1 + amount * pulse())
            }
        } else {
            content
        }
    }

    private func pulse() -> CGFloat {
        guard isPlaying else { return 0 }
        let levels = AudioAnalyzer.shared.snapshot()
        guard levels.kickAge.isFinite, levels.kickAge < 0.4 else { return 0 }
        // Fast rise (~15 ms) then exponential settle, so it reads as a hit rather than a wobble.
        let age = levels.kickAge
        let envelope = min(1, age / 0.015) * exp(-age * 9)
        return CGFloat(envelope) * CGFloat(0.5 + 0.5 * levels.kickStrength)
    }
}

/// Live tempo from the kick drum, e.g. «124 bpm»; blank until it has heard enough kicks.
struct TempoText: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if isPlaying, let bpm = AudioAnalyzer.shared.tempo() {
                Text("\(Int(bpm.rounded())) bpm")
                    .contentTransition(.numericText())
            }
        }
    }
}

extension View {
    func kickBounce(isPlaying: Bool, amount: CGFloat = 0.035) -> some View {
        modifier(KickBounce(isPlaying: isPlaying, amount: amount))
    }
}
