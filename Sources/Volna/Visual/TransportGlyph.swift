import SwiftUI

/// Our own transport icons: sharp-cornered triangles and bars, like terminal glyphs, instead of
/// the soft rounded system symbols that looked out of place next to the mono type.
struct TransportGlyph: Shape {
    enum Kind { case play, pause, next, previous }

    var kind: Kind

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        var p = Path()
        func triangle(from left: CGFloat, to right: CGFloat, pointingRight: Bool) {
            if pointingRight {
                p.move(to: CGPoint(x: x + left, y: y))
                p.addLine(to: CGPoint(x: x + right, y: y + h / 2))
                p.addLine(to: CGPoint(x: x + left, y: y + h))
            } else {
                p.move(to: CGPoint(x: x + right, y: y))
                p.addLine(to: CGPoint(x: x + left, y: y + h / 2))
                p.addLine(to: CGPoint(x: x + right, y: y + h))
            }
            p.closeSubpath()
        }
        switch kind {
        case .play:
            triangle(from: w * 0.12, to: w * 0.95, pointingRight: true)
        case .pause:
            p.addRect(CGRect(x: x + w * 0.16, y: y, width: w * 0.24, height: h))
            p.addRect(CGRect(x: x + w * 0.60, y: y, width: w * 0.24, height: h))
        case .next:
            triangle(from: 0, to: w * 0.44, pointingRight: true)
            triangle(from: w * 0.40, to: w * 0.84, pointingRight: true)
            p.addRect(CGRect(x: x + w * 0.86, y: y, width: w * 0.14, height: h))
        case .previous:
            p.addRect(CGRect(x: x, y: y, width: w * 0.14, height: h))
            triangle(from: w * 0.16, to: w * 0.60, pointingRight: false)
            triangle(from: w * 0.56, to: w, pointingRight: false)
        }
        return p
    }
}

extension TransportGlyph {
    /// The glyph at a given height, keeping each kind's proportions.
    static func icon(_ kind: Kind, height: CGFloat) -> some View {
        let aspect: CGFloat = switch kind {
        case .play: 0.9
        case .pause: 0.8
        case .next, .previous: 1.35
        }
        return TransportGlyph(kind: kind).frame(width: height * aspect, height: height)
    }
}

/// Previous / next: our glyph in a material ring.
struct GlassTransportButton: View {
    let kind: TransportGlyph.Kind
    var size: CGFloat = 60
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TransportGlyph.icon(kind, height: size * 0.26)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(.circle)
                .contentLayerControl(in: Circle())
        }
        .buttonStyle(.plain)
    }
}
