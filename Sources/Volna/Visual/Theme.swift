import Observation
import SwiftUI
import UIKit

/// Cover art decoded into a plain 8-bit RGBA buffer, shared by the visualizer and the accent picker.
enum CoverPixels {
    struct Image: Sendable {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    private static let cache = Cache()

    static func load(_ uri: String?, side: Int = 256) async -> Image? {
        guard let uri, let url = CoverURL.make(uri, size: 400) else { return nil }
        if let hit = await cache.get(uri) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let cg = UIImage(data: data)?.cgImage
        else { return nil }
        let image = await Task.detached(priority: .userInitiated) { decode(cg, side: side) }.value
        if let image { await cache.put(uri, image) }
        return image
    }

    private static func decode(_ cg: CGImage, side: Int) -> Image? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? Image(bytes: bytes, width: side, height: side) : nil
    }

    private actor Cache {
        private var items: [(String, Image)] = []
        private static let limit = 6

        func get(_ key: String) -> Image? { items.first { $0.0 == key }?.1 }

        func put(_ key: String, _ image: Image) {
            items.removeAll { $0.0 == key }
            items.append((key, image))
            if items.count > Self.limit { items.removeFirst() }
        }
    }
}

/// App accent: the acid default, or the most characterful colour of the playing cover.
@MainActor
@Observable
final class Theme {
    static let shared = Theme()
    static let defaultAccent = SIMD3<Float>(0.776, 1.0, 0.239)
    static let coverAccentKey = "coverAccent"

    private(set) var accentRGB = Theme.defaultAccent

    var accent: Color {
        Color(red: Double(accentRGB.x), green: Double(accentRGB.y), blue: Double(accentRGB.z))
    }

    static var followsCover: Bool {
        UserDefaults.standard.object(forKey: coverAccentKey) as? Bool ?? true
    }

    /// Three colours for the smoke visualizer: core, glow and shadow. Always from the cover,
    /// independent of the accent toggle, so the cloud matches the art like in Yandex.
    private(set) var smokePalette: [SIMD3<Float>] = Theme.defaultSmoke

    /// Yellow core, magenta glow, violet shadow — used for grey covers.
    static let defaultSmoke: [SIMD3<Float>] = [[1.0, 0.85, 0.15], [0.95, 0.2, 0.75], [0.35, 0.12, 0.8]]

    func update(coverURI: String?) async {
        let pixels = await CoverPixels.load(coverURI)
        var target = Self.defaultAccent
        if Self.followsCover, let pixels, let picked = Self.dominantAccent(pixels) {
            target = picked
        }
        let smoke = pixels.flatMap(Self.smokeColors) ?? Self.defaultSmoke
        withAnimation(.easeInOut(duration: 0.6)) {
            if target != accentRGB { accentRGB = target }
            smokePalette = smoke
        }
    }

    /// Two strongest hue families plus a darker shadow, all pushed vivid.
    nonisolated static func smokeColors(_ image: CoverPixels.Image) -> [SIMD3<Float>]? {
        let buckets = 12
        var weight = [Double](repeating: 0, count: buckets)
        var hues = [Double](repeating: 0, count: buckets)
        let step = max(1, image.width / 32)
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                let i = (y * image.width + x) * 4
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                UIColor(red: CGFloat(image.bytes[i]) / 255, green: CGFloat(image.bytes[i + 1]) / 255,
                        blue: CGFloat(image.bytes[i + 2]) / 255, alpha: 1)
                    .getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                guard s > 0.25, v > 0.2 else { continue }
                let bucket = min(buckets - 1, Int(h * CGFloat(buckets)))
                let w = Double(s * s * v)
                weight[bucket] += w
                hues[bucket] += Double(h) * w
            }
        }
        let ranked = weight.indices.sorted { weight[$0] > weight[$1] }
        guard let first = ranked.first, weight[first] > 32 * 32 * 0.01 else { return nil }
        let primary = hues[first] / weight[first]
        let second = ranked.dropFirst().first { weight[$0] > weight[first] * 0.25 && abs($0 - first) > 1 }
        let secondary = second.map { hues[$0] / weight[$0] } ?? (primary + 0.12).truncatingRemainder(dividingBy: 1)

        func rgb(_ hue: Double, _ saturation: CGFloat, _ brightness: CGFloat) -> SIMD3<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(hue: CGFloat(hue), saturation: saturation, brightness: brightness, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
        return [rgb(primary, 0.75, 1.0), rgb(secondary, 0.85, 0.95), rgb((primary + 0.9).truncatingRemainder(dividingBy: 1), 0.85, 0.55)]
    }

    /// Strongest hue family by saturation × brightness, pushed bright enough to read on black.
    /// Returns nil for grey covers so they keep the default accent.
    nonisolated static func dominantAccent(_ image: CoverPixels.Image) -> SIMD3<Float>? {
        let buckets = 12
        var weight = [CGFloat](repeating: 0, count: buckets)
        var sums = [SIMD3<Double>](repeating: .zero, count: buckets)
        let step = max(1, image.width / 32)
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                let i = (y * image.width + x) * 4
                let r = CGFloat(image.bytes[i]) / 255, g = CGFloat(image.bytes[i + 1]) / 255, b = CGFloat(image.bytes[i + 2]) / 255
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                guard s > 0.28, v > 0.22 else { continue }
                let bucket = min(buckets - 1, Int(h * CGFloat(buckets)))
                let w = s * s * v
                weight[bucket] += w
                sums[bucket] += SIMD3(Double(r), Double(g), Double(b)) * Double(w)
            }
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > CGFloat(32 * 32) * 0.012
        else { return nil }
        let avg = sums[best] / Double(weight[best])
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(avg.x), green: CGFloat(avg.y), blue: CGFloat(avg.z), alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let tuned = UIColor(hue: h, saturation: min(max(s, 0.55), 0.9), brightness: max(v, 0.92), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        tuned.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}
