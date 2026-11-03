import Foundation

/// User-tunable playback options, persisted in UserDefaults.
enum Preferences {
    enum Quality: String, CaseIterable, Identifiable {
        case lossless
        case high
        case efficient

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lossless: "Lossless (FLAC)"
            case .high: "Высокое (MP3 320)"
            case .efficient: "Экономное (AAC)"
            }
        }
    }

    enum Key {
        static let quality = "quality"
        static let crossfade = "crossfadeSeconds"
        static let waveSeeds = "waveSettingSeeds"
    }

    static var quality: Quality {
        Quality(rawValue: UserDefaults.standard.string(forKey: Key.quality) ?? "") ?? .high
    }

    /// 0 means gapless hand-off without fading.
    static var crossfade: Double {
        UserDefaults.standard.double(forKey: Key.crossfade)
    }

    static var waveSeeds: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.waveSeeds) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.waveSeeds) }
    }
}
