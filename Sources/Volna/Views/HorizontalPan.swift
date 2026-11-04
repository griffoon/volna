import SwiftUI
import UIKit

/// A sideways-only drag. It begins only when the finger moves more horizontally than vertically;
/// otherwise it fails at once, so vertical swipes go to whatever is underneath (the page scroll,
/// the player sheet's pull-down). SwiftUI's DragGesture can't do this inside a ScrollView.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    struct Value {
        /// Horizontal travel since the drag began, in points.
        let translation: CGFloat
        /// Where a flick would carry it: translation plus a share of the velocity.
        let predicted: CGFloat
    }

    var onBegan: () -> Void = {}
    var onChanged: (Value) -> Void
    var onEnded: (Value) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = context.converter.localTranslation?.x ?? 0
        let vx = context.converter.localVelocity?.x ?? 0
        let value = Value(translation: x, predicted: x + vx * 0.25)
        switch recognizer.state {
        case .began: onBegan(); onChanged(value)
        case .changed: onChanged(value)
        case .ended, .cancelled, .failed: onEnded(value)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.2
        }

        /// Other drags under the finger (the sheet's pull-to-close, page scrolling) wait until this
        /// one has decided. A sideways swipe then never also closes the player; a vertical one makes
        /// this fail at once, so they start without delay.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other !== recognizer
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
