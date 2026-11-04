import MediaPlayer
import SwiftUI

/// The phone's own volume (same as the buttons and Control Center), as a slider in our colours.
/// Apps can only change system volume through MPVolumeView; the route button is hidden.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        view.tintColor = UIColor(Brand.acid)
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = UIColor(Brand.acid)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.2)
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = UIColor(Brand.acid)
        }
    }
}
