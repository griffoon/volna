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

    func update(coverURI: String?) async {
        var target = Self.defaultAccent
        if Self.followsCover, let pixels = await CoverPixels.load(coverURI),
           let picked = Self.dominantAccent(pixels) {
            target = picked
        }
        guard target != accentRGB else { return }
        withAnimation(.easeInOut(duration: 0.6)) { accentRGB = target }
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
