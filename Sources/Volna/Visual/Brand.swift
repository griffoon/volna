import CoreText
import SwiftUI

/// Terminal look: monochrome tunnel, one acid accent, Dela Gothic One for display text.
enum Brand {
    /// Accent: the acid default or the cover's colour (see `Theme`). Reading it in a view body
    /// subscribes that view to accent changes.
    @MainActor static var acid: Color { Theme.shared.accent }
    static let ink = Color(red: 0.02, green: 0.02, blue: 0.024)
    static let displayFontName = "DelaGothicOne-Regular"

    /// Registers bundled fonts once; Info.plist `UIAppFonts` is not needed.
    static func registerFonts() {
        guard let url = Bundle.module.url(forResource: "DelaGothicOne-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func display(_ size: CGFloat) -> Font {
        .custom(displayFontName, fixedSize: size)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
