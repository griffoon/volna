import Accelerate
import Foundation
import os

/// Equalizer and loudness settings shared between the UI and the audio thread.
/// The audio tap reads a snapshot every callback and rebuilds its filters when `version` moves.
final class AudioProcessing: @unchecked Sendable {
    struct State: Sendable {
        var eqEnabled = false
        var gains = [Float](repeating: 0, count: AudioProcessing.frequencies.count)
        var normalize = true
        var version = 0
    }

    static let shared = AudioProcessing()
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Float> = -12...12
    /// Streaming-platform target loudness.
    static let targetLUFS = -14.0

    private static let gainsKey = "eqGains", enabledKey = "eqEnabled", normalizeKey = "normalizeLoudness"
    private let state: OSAllocatedUnfairLock<State>

    private init() {
        var initial = State()
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: Self.gainsKey) as? [Float], saved.count == Self.frequencies.count {
            initial.gains = saved
        }
        initial.eqEnabled = defaults.bool(forKey: Self.enabledKey)
        initial.normalize = defaults.object(forKey: Self.normalizeKey) as? Bool ?? true
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func snapshot() -> State { state.withLock { $0 } }

    func update(_ change: (inout State) -> Void) {
        let new = state.withLock { s -> State in
            change(&s)
            s.version &+= 1
            return s
        }
        let defaults = UserDefaults.standard
        defaults.set(new.gains, forKey: Self.gainsKey)
        defaults.set(new.eqEnabled, forKey: Self.enabledKey)
        defaults.set(new.normalize, forKey: Self.normalizeKey)
    }

    /// Linear gain that brings a track to the target loudness without its true peak passing −1 dBTP.
    static func normalizationGain(for loudness: Loudness?) -> Float {
        guard let i = loudness?.i else { return 1 }
        var db = targetLUFS - i
        if let tp = loudness?.tp { db = min(db, -1 - tp) }
        db = min(max(db, -12), 9)
        return Float(pow(10, db / 20))
    }

    /// RBJ peaking-filter sections for vDSP.Biquad: b0, b1, b2, a1, a2 per band.
    static func coefficients(gains: [Float], sampleRate: Double) -> [Double] {
        var result: [Double] = []
        let q = 1.1
        for (index, frequency) in frequencies.enumerated() {
            let f = min(Double(frequency), sampleRate * 0.45)
            let a = pow(10, Double(gains[index]) / 40)
            let w0 = 2 * Double.pi * f / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha / a
            result += [(1 + alpha * a) / a0, -2 * cos(w0) / a0, (1 - alpha * a) / a0,
                       -2 * cos(w0) / a0, (1 - alpha / a) / a0]
        }
        return result
    }

    /// Headroom so boosted bands don't clip: half of the largest boost.
    static func preamp(gains: [Float]) -> Float {
        let boost = max(0, gains.max() ?? 0)
        return Float(pow(10, -Double(boost) * 0.5 / 20))
    }
}

/// Built-in starting points for the equalizer.
enum EQPreset: String, CaseIterable, Identifiable {
    case flat, bass, vocal, electronic, rock, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Ровно"
        case .bass: "Бас+"
        case .vocal: "Вокал"
        case .electronic: "Электроника"
        case .rock: "Рок"
        case .night: "Ночь"
        }
    }

    var gains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [7, 6, 4, 1, 0, 0, 0, 0, 0, 0]
        case .vocal: [-2, -1, 0, 1, 3, 4, 3, 1, 0, -1]
        case .electronic: [5, 4, 1, 0, -2, 1, 1, 3, 4, 5]
        case .rock: [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]
        case .night: [-3, -2, -1, 0, 1, 1, 0, -2, -4, -6]
        }
    }
}
