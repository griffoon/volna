import UIKit

/// One place for tactile feedback so its weight stays consistent:
/// `tick` for passing detents and toggles, `tap` for ordinary buttons,
/// `thump` for the big moments (play, switching tracks by swipe), `slam` for dislike.
@MainActor
enum Haptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Barely there: scrubbing past marks, chips, segmented choices.
    static func tick() { selection.selectionChanged() }

    /// Soft press for secondary buttons.
    static func tap() { soft.impactOccurred(intensity: 0.7) }

    /// Next / previous buttons.
    static func step() { light.impactOccurred() }

    /// Play, pause, a track switched by swipe.
    static func thump() { medium.impactOccurred() }

    /// Starting My Wave from silence.
    static func launch() { heavy.impactOccurred() }

    /// Dislike: short and hard so it feels final.
    static func slam() { rigid.impactOccurred(intensity: 1) }

    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func error() { notification.notificationOccurred(.error) }
}
