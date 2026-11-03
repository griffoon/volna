import SwiftUI
import UIKit

/// The current cover redrawn as a field of ` .01` glyphs — the player's backdrop.
/// Computed once per cover and size, so it costs nothing while the track plays.
struct AsciiCover: View {
    let uri: String?
    /// Glyph columns across the width; rows follow from the 0.6 × 1.2 cell of the mono font.
    var columns = 46

    @State private var art = ""

    private static let ramp: [Character] = [" ", " ", ".", "0", "1"]

    var body: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / CGFloat(columns)
            let fontSize = cellW / 0.6
            let rows = max(1, Int(geo.size.height / (fontSize * 1.2)))
            Text(art)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .lineSpacing(0)
                .fixedSize()
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentTransition(.opacity)
                .task(id: "\(uri ?? "")-\(rows)") {
                    let built = await Self.render(uri: uri, columns: columns, rows: rows)
                    withAnimation(.easeInOut(duration: 0.4)) { art = built }
                }
        }
        .accessibilityHidden(true)
    }

    private static func render(uri: String?, columns: Int, rows: Int) async -> String {
        guard let url = CoverURL.make(uri, size: 200),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data)?.cgImage
        else { return "" }
        return await Task.detached(priority: .utility) {
            asciiArt(from: image, columns: columns, rows: rows)
        }.value
    }

    /// Cover is cropped to the screen's aspect, sampled to grayscale and mapped onto the ramp.
    private static func asciiArt(from image: CGImage, columns: Int, rows: Int) -> String {
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            // Aspect-fill: glyph cells are twice as tall as wide, so the target is 2× taller in pixels.
            let targetAspect = CGFloat(columns) / (CGFloat(rows) * 2)
            let imageAspect = CGFloat(image.width) / CGFloat(image.height)
            var drawRect = CGRect(x: 0, y: 0, width: columns, height: rows)
            if imageAspect > targetAspect {
                let w = CGFloat(rows) * imageAspect * 2
                drawRect = CGRect(x: (CGFloat(columns) - w) / 2, y: 0, width: w, height: CGFloat(rows))
            } else {
                let h = CGFloat(columns) / imageAspect / 2
                drawRect = CGRect(x: 0, y: (CGFloat(rows) - h) / 2, width: CGFloat(columns), height: h)
            }
            ctx.draw(image, in: drawRect)
            return true
        }
        guard drawn else { return "" }

        // Stretch contrast so dark and light covers both use the whole ramp.
        let lo = Double(pixels.min() ?? 0), hi = Double(pixels.max() ?? 255)
        let span = max(hi - lo, 1)
        var out = ""
        out.reserveCapacity((columns + 1) * rows)
        for row in 0..<rows {
            for col in 0..<columns {
                let v = (Double(pixels[row * columns + col]) - lo) / span
                let index = min(ramp.count - 1, Int(pow(v, 1.3) * Double(ramp.count)))
                out.append(ramp[index])
            }
            if row < rows - 1 { out.append("\n") }
        }
        return out
    }
}
