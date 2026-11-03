import UIKit

/// «Тактильный бас»: the phone knocks in your hand on every kick drum.
/// The analyzer reads audio ahead of the playhead, so each knock is scheduled for the exact moment
/// its kick is heard instead of being fired after the fact.
/// Off by default; iOS only plays haptics while the app is in the foreground.
@MainActor
enum HapticBass {
    static let storageKey = "hapticBass"
    /// User nudge in milliseconds: positive fires later, negative earlier.
    static let offsetKey = "hapticBassOffset"
    static let offsetRange: ClosedRange<Double> = -120...120

    private static let generator = UIImpactFeedbackGenerator(style: .heavy)
    /// How far ahead to look for kicks; must stay shorter than the gap between two kicks.
    private static let horizon = 0.12
    private static let poll: Duration = .milliseconds(40)
    /// The Taptic Engine needs a moment to spin up, so knocks are triggered this much early.
    private static let engineLead = 0.012

    static func run(player: PlayerEngine) async {
        var scheduled = Set<UInt64>()
        generator.prepare()
        while !Task.isCancelled {
            try? await Task.sleep(for: poll)
            guard player.isPlaying, UIApplication.shared.applicationState == .active else {
                scheduled.removeAll()
                continue
            }
            let offset = UserDefaults.standard.double(forKey: offsetKey) / 1000
            for (kick, delay) in AudioAnalyzer.shared.upcomingKicks(horizon: horizon + engineLead - offset)
            where !scheduled.contains(kick.index) {
                scheduled.insert(kick.index)
                let wait = max(0, delay - engineLead + offset)
                let intensity = CGFloat(min(1, 0.4 + kick.strength * 0.6))
                Task { @MainActor in
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait), tolerance: .zero) }
                    guard player.isPlaying else { return }
                    generator.impactOccurred(intensity: intensity)
                    generator.prepare()
                }
            }
            if scheduled.count > 256 { scheduled = Set(scheduled.sorted().suffix(32)) }
        }
    }
}
