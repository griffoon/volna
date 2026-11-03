import MetalKit
import SwiftUI
import UIKit

/// The playing cover redrawn as ASCII that reacts to the music in one of four effects
/// (see `VisualizerEffect`); bass, mids and highs each drive a different part of it.
/// The shader is compiled on device from source because xtool builds have no Metal compiler.
struct CoverVisualizer: UIViewRepresentable {
    var coverURI: String?
    var ascii: Bool
    var isPlaying: Bool
    /// False pauses rendering entirely, e.g. when scrolled off screen.
    var active = true
    var accent: SIMD3<Float>
    var effect: VisualizerEffect = .smoke
    var palette: [SIMD3<Float>] = Theme.defaultSmoke

    func makeCoordinator() -> VisualizerRenderer { VisualizerRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.ascii = ascii
        renderer.isPlaying = isPlaying
        renderer.accent = accent
        renderer.effect = effect
        renderer.palette = palette
        renderer.setCover(coverURI)
        view.isPaused = !active
    }

    static func dismantleUIView(_ view: MTKView, coordinator: VisualizerRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// Last renderer failure, shown on screen so it can be reported from a screenshot.
@MainActor
@Observable
final class TunnelDiagnostics {
    static let shared = TunnelDiagnostics()
    var message: String?

    nonisolated static func report(_ message: String) {
        Task { @MainActor in
            if shared.message == nil { shared.message = message }
        }
    }
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var grid: SIMD2<Float>
        var glyphCount: Float
        var ascii: Float
        var time: Float
        var bass: Float
        var mid: Float
        var high: Float
        var kick: Float
        var flash: Float
        var midHit: Float
        var highHit: Float
        var hasCover: Float
        var effect: Float
        var beatPhase: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
        var accent: SIMD4<Float>
        var core: SIMD4<Float>
        var glow: SIMD4<Float>
        var shade: SIMD4<Float>
    }

    /// Binary glyph ramp, darkest first.
    private static let glyphs = [" ", ".", "0", "1"]
    /// Cell size in points; rows are 1.75× taller than wide, like terminal text.
    private static let cell: Float = 6

    let device = MTLCreateSystemDefaultDevice()
    var ascii = true
    var isPlaying = false
    var accent = Theme.defaultAccent
    var effect: VisualizerEffect = .smoke
    var palette: [SIMD3<Float>] = Theme.defaultSmoke

    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var atlas: MTLTexture?
    private var cover: MTLTexture?
    private var sampler: MTLSamplerState?
    private var coverURI: String?
    private var coverTask: Task<Void, Never>?

    // Audio state, smoothed per frame.
    private var time: Float = 0
    private var bass: Float = 0, mid: Float = 0, high: Float = 0
    private var midAverage: Float = 0, highAverage: Float = 0
    private var midHit: Float = 0, highHit: Float = 0
    private var kick: Float = 0, flash: Float = 0
    private var lastBeat: UInt64 = 0
    /// 0 on each beat, then sweeps past 1; drives the scanner beam.
    private var beatPhase: Float = 1.3
    private var lastFrame = CACurrentMediaTime()

    override init() {
        super.init()
        guard let device else {
            TunnelDiagnostics.report("no Metal device")
            return
        }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "visVertex")
            desc.fragmentFunction = library.makeFunction(name: "visFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            TunnelDiagnostics.report("shader: \(error.localizedDescription)")
        }
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .mirrorRepeat
        samplerDesc.tAddressMode = .mirrorRepeat
        sampler = device.makeSamplerState(descriptor: samplerDesc)
        atlas = makeAtlas(device: device)
    }

    func setCover(_ uri: String?) {
        guard uri != coverURI else { return }
        coverURI = uri
        coverTask?.cancel()
        guard let device else { return }
        coverTask = Task { [weak self] in
            guard let image = await CoverPixels.load(uri), !Task.isCancelled else { return }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                                height: image.height, mipmapped: false)
            desc.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: desc) else { return }
            image.bytes.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
            }
            await MainActor.run {
                guard let self, self.coverURI == uri else { return }
                self.cover = texture
                self.flash = 1
            }
        }
    }

    /// Glyph strip in a plain 8-bit RGBA bitmap copied straight into a texture.
    private func makeAtlas(device: MTLDevice) -> MTLTexture? {
        let cellW = 32, cellH = 56
        let width = cellW * Self.glyphs.count, height = cellH
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPushContext(ctx)
            let font = UIFont.monospacedSystemFont(ofSize: CGFloat(cellH) * 0.72, weight: .bold)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: style]
            for (i, glyph) in Self.glyphs.enumerated() {
                let rect = CGRect(x: CGFloat(i * cellW), y: (CGFloat(cellH) - font.lineHeight) / 2,
                                  width: CGFloat(cellW), height: font.lineHeight)
                glyph.draw(in: rect, withAttributes: attrs)
            }
            UIGraphicsPopContext()
            return true
        }
        guard drawn else {
            TunnelDiagnostics.report("atlas: CGContext failed")
            return nil
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let pipeline, let atlas,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer()
        else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.05))
        lastFrame = now
        updateAudio(dt: dt)

        let w = Float(view.drawableSize.width), h = Float(view.drawableSize.height)
        let scale = Float(view.contentScaleFactor)
        let cols = max(8, (w / (Self.cell * scale)).rounded())
        let rows = max(8, (h / (Self.cell * 1.75 * scale)).rounded())

        if let enc = buffer.makeRenderCommandEncoder(descriptor: pass) {
            var u = Uniforms(
                resolution: [w, h], grid: [cols, rows], glyphCount: Float(Self.glyphs.count),
                ascii: ascii ? 1 : 0, time: time, bass: bass, mid: mid, high: high, kick: kick, flash: flash,
                midHit: midHit, highHit: highHit, hasCover: cover == nil ? 0 : 1,
                effect: Float(effect.rawValue), beatPhase: beatPhase,
                accent: SIMD4(accent, 1),
                core: SIMD4(palette[safe: 0] ?? accent, 1),
                glow: SIMD4(palette[safe: 1] ?? accent, 1),
                shade: SIMD4(palette[safe: 2] ?? accent, 1)
            )
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(cover ?? atlas, index: 0)
            enc.setFragmentTexture(atlas, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        buffer.addCompletedHandler { done in
            if let error = done.error { TunnelDiagnostics.report("gpu: \(error.localizedDescription)") }
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Splits the analyzer's six bands into bass / mids / highs, each with a level and a "hit"
    /// (how far it jumps above its own recent average), so steady pads and sharp hits look different.
    private func updateAudio(dt: Float) {
        let levels = AudioAnalyzer.shared.snapshot()
        let live = isPlaying && Date().timeIntervalSince(levels.updated) < 0.5
        let b = levels.bands
        let rawBass = live ? max(b[0], b[1]) : 0
        let rawMid = live ? max(b[2], b[3]) : 0
        let rawHigh = live ? max(b[4], b[5]) : 0

        bass += (rawBass - bass) * min(1, dt * 14)
        mid += (rawMid - mid) * min(1, dt * 8)
        high += (rawHigh - high) * min(1, dt * 18)
        midAverage += (rawMid - midAverage) * min(1, dt * 1.5)
        highAverage += (rawHigh - highAverage) * min(1, dt * 1.5)
        midHit = max(midHit * exp(-dt * 6), min(1, max(0, rawMid - midAverage) * 5))
        highHit = max(highHit * exp(-dt * 10), min(1, max(0, rawHigh - highAverage) * 6))

        if live, levels.beat != lastBeat { kick = 1; flash = max(flash, 0.8); beatPhase = 0 }
        beatPhase = min(1.3, beatPhase + dt * 2.1)
        lastBeat = levels.beat
        kick *= exp(-dt * 7)
        flash *= exp(-dt * 9)
        time += dt * (isPlaying ? 0.6 + bass * 1.4 : 0.15)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; };

    vertex VOut visVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    struct U {
        float2 res; float2 grid;
        float n; float ascii; float time; float bass;
        float mid; float high; float kick; float flash;
        float midHit; float highHit; float hasCover; float effect;
        float beatPhase; float pad0; float pad1; float pad2;
        float4 accent; float4 core; float4 glow; float4 shade;
    };

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

    // Square cover filling the screen height, centred.
    float2 coverUV(float2 cuv, float2 res) { return (cuv - 0.5) * float2(res.x / res.y, 1.0) + 0.5; }

    float coverL(texture2d<float> cover, sampler smp, float2 cuv, float2 res, float hasCover, float t) {
        if (hasCover < 0.5) {
            float r = length((cuv - 0.5) * float2(res.x / res.y, 1.0));
            return 0.3 * (0.5 + 0.5 * sin(r * 20.0 - t * 2.0));
        }
        return luma(cover.sample(smp, coverUV(cuv, res)).rgb);
    }

    float noise2(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
    }

    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 5; i++) {
            v += a * noise2(p);
            p = float2x2(1.6, 1.2, -1.2, 1.6) * p;
            a *= 0.5;
        }
        return v;
    }

    // Smoke: a glowing cloud in the cover's colours, domain-warped so it folds like light in fog.
    // Bass swells and brightens it, mids speed up the folding, highs draw fine light streaks.
    float4 smoke(float2 uv, constant U& u) {
        float2 p = (uv - float2(0.5, 0.38)) * float2(u.res.x / u.res.y, 1.0) * 1.6;
        float t = u.time * 0.18 * (1.0 + u.mid * 0.8);
        float2 q = float2(fbm(p + t), fbm(p - t + 3.1));
        float2 r = float2(fbm(p + 2.0 * q + float2(1.7, 9.2) + t * 1.3),
                          fbm(p + 2.0 * q + float2(8.3, 2.8) - t));
        float f = fbm(p + 2.6 * r);
        float radius = length(p) * (1.15 - 0.28 * u.bass - 0.18 * u.kick);
        float cloud = smoothstep(1.05, 0.05, radius + (f - 0.5) * 0.6);
        float3 col = mix(u.shade.rgb * 0.7, u.glow.rgb, clamp(f * f * 2.4, 0.0, 1.0));
        col = mix(col, u.core.rgb, clamp(length(q) * 0.85 - 0.15, 0.0, 1.0));
        col += u.core.rgb * pow(clamp(f, 0.0, 1.0), 3.0) * (0.6 + 1.4 * u.bass);
        float intensity = cloud * (0.45 + 0.9 * f) * (0.75 + 0.45 * u.bass + 0.35 * u.kick);
        float streak = pow(abs(sin(p.x * 14.0 + f * 7.0 + t * 5.0)), 48.0) * (u.high * 0.6 + u.highHit) * cloud;
        float3 outc = col * intensity + streak * u.glow.rgb + u.flash * 0.08 * u.core.rgb;
        return float4(outc, 1.0);
    }

    fragment float4 visFragment(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                                texture2d<float> cover [[texture(0)]], texture2d<float> atlas [[texture(1)]],
                                sampler smp [[sampler(0)]]) {
        float2 uv = in.pos.xy / u.res;
        if (int(u.effect + 0.5) == 4) { return smoke(uv, u); }
        float2 grid = u.ascii > 0.5 ? u.grid : u.res / 3.0;
        float2 g = uv * grid;
        float2 cell = floor(g);
        float2 cuv = (cell + 0.5) / grid;
        float2 local = fract(g);
        float t = u.time;
        float l = 0.0, hot = 0.0, jitter = 0.0;
        int fx = int(u.effect + 0.5);

        if (fx == 0) {
            // Breath: the image never moves; light, density and glyph choice do.
            l = coverL(cover, smp, cuv, u.res, u.hasCover, t);
            l = clamp((l - 0.5) * (1.2 + 0.5 * u.bass) + 0.5 + 0.22 * u.bass + 0.12 * u.kick, 0.0, 1.0);
            jitter = (hash21(cell + floor(t * 8.0)) - 0.5) * u.mid * 0.5;
            hot = step(1.0 - u.high * 0.05 - u.highHit * 0.14, hash21(cell + floor(t * 20.0)));
        } else if (fx == 1) {
            // Relief: luminance is height; bass pushes bright regions toward the viewer.
            float2 c = cuv - 0.5;
            c.x += c.y * u.mid * 0.06 * sin(t * 0.8);
            float h0 = coverL(cover, smp, cuv, u.res, u.hasCover, t);
            float2 warped = 0.5 + c * (1.0 - (0.10 * u.bass + 0.07 * u.kick) * h0);
            l = coverL(cover, smp, warped, u.res, u.hasCover, t);
            float hx = coverL(cover, smp, warped + float2(1.0 / grid.x, 0.0), u.res, u.hasCover, t);
            float hy = coverL(cover, smp, warped + float2(0.0, 1.0 / grid.y), u.res, u.hasCover, t);
            float light = clamp((l - hx) * 3.0 + (l - hy) * 3.0, -1.0, 1.0);
            l = clamp(l * (0.75 + 0.5 * u.bass) + light * (0.25 + 0.5 * u.bass), 0.0, 1.0);
            hot = smoothstep(0.85, 1.0, l) * (0.4 + u.bass);
        } else if (fx == 2) {
            // Scanner: a beam sweeps down once per beat and develops the image; a trail fades behind.
            float base = coverL(cover, smp, cuv, u.res, u.hasCover, t);
            float d = u.beatPhase - cuv.y;
            float trail = d > 0.0 ? exp(-d * 5.0) : 0.0;
            float head = exp(-abs(d) * 60.0);
            float noise = step(1.0 - u.highHit * 0.2 - u.high * 0.03, hash21(cell + floor(t * 30.0)));
            l = clamp(base * (0.18 + 0.9 * trail) + head * 0.8 + noise * 0.5, 0.0, 1.0);
            hot = head + noise;
        } else {
            // Matrix: falling columns; the cover shows where the rain is bright.
            float base = coverL(cover, smp, cuv, u.res, u.hasCover, t);
            float speed = 0.25 + hash21(float2(cell.x, 3.0)) * 0.5;
            float headY = fract(t * speed * (0.6 + u.bass * 1.4) + hash21(float2(cell.x, 9.0)));
            float d = fract(headY - cuv.y);
            float trail = exp(-d * (9.0 - u.mid * 5.0));
            float tip = exp(-d * 120.0);
            l = clamp(base * (0.15 + 1.1 * trail) + tip * 0.6, 0.0, 1.0);
            jitter = (hash21(cell + floor(t * 14.0)) - 0.5) * 0.4 * trail;
            hot = tip + step(1.0 - u.highHit * 0.1, hash21(cell + floor(t * 22.0)));
        }

        l *= smoothstep(1.2, 0.25, length((cuv - 0.5) * float2(u.res.x / u.res.y, 1.0)));
        float3 accent = u.accent.rgb;
        float3 col = mix(float3(0.92), accent, clamp(hot, 0.0, 1.0));
        if (u.ascii < 0.5) {
            return float4(col * l, 1.0);
        }
        float gi = floor(clamp(l + jitter, 0.0, 0.999) * u.n);
        float m = atlas.sample(smp, float2((gi + local.x) / u.n, local.y)).r;
        return float4(col * m * (0.35 + 0.85 * l), 1.0);
    }
    """
}

/// Which way the cover reacts to music on the Wave screen.
enum VisualizerEffect: Int, CaseIterable, Identifiable {
    case breath, relief, scanner, matrix, smoke

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .breath: "Дыхание"
        case .relief: "Рельеф"
        case .scanner: "Сканер"
        case .matrix: "Матрица"
        case .smoke: "Дым"
        }
    }

    var summary: String {
        switch self {
        case .breath: "обложка стоит, бас даёт свет, синт — мерцание, верха — вспышки"
        case .relief: "яркие места выпирают на басу"
        case .scanner: "на каждый удар луч проявляет обложку"
        case .matrix: "обложка проступает сквозь дождь символов"
        case .smoke: "светящееся облако в цветах обложки, как в Яндексе"
        }
    }

    static let storageKey = "visualizerEffect"
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
