import UIKit

/// «Тактильный бас»: the phone knocks in your hand on every detected kick.
/// Off by default; iOS only plays haptics while the app is in the foreground.
@MainActor
enum HapticBass {
    static let storageKey = "hapticBass"

    private static let generator = UIImpactFeedbackGenerator(style: .heavy)
    /// How often the analyzer is polled for new beats.
    private static let poll: Duration = .milliseconds(16)

    static func run(player: PlayerEngine) async {
        var lastBeat = AudioAnalyzer.shared.snapshot().beat
        generator.prepare()
        while !Task.isCancelled {
            try? await Task.sleep(for: poll)
            let levels = AudioAnalyzer.shared.snapshot()
            guard levels.beat != lastBeat else { continue }
            lastBeat = levels.beat
            guard player.isPlaying, UIApplication.shared.applicationState == .active else { continue }
            generator.impactOccurred(intensity: CGFloat(min(1, 0.45 + levels.bass * 0.7)))
            generator.prepare()
        }
    }
}
