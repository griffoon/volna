import Foundation
import Observation

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: Double
    let text: String

    var isBreak: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum Lyrics: Sendable {
    case synced([LyricLine])
    case plain(String)
    case unavailable
}

enum LRCParser {
    /// Matches `[mm:ss.xx]`; a line may carry several stamps.
    nonisolated(unsafe) private static let stamp = #/\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]/#

    static func parse(_ source: String) -> [LyricLine] {
        var entries: [(Double, String)] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let matches = line.matches(of: stamp)
            guard let last = matches.last else { continue }
            let text = String(line[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(match.1) ?? 0
                let seconds = Double(match.2) ?? 0
                let fraction = match.3.map { Double("0.\($0)") ?? 0 } ?? 0
                entries.append((minutes * 60 + seconds + fraction, text))
            }
        }
        return entries
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

@MainActor
@Observable
final class LyricsLoader {
    private(set) var lyrics: Lyrics?
    private(set) var writers: [String] = []
    /// Where the text came from when it isn't Yandex's own.
    private(set) var source: String?
    private var cache: [String: (Lyrics, [String], String?)] = [:]

    func load(_ track: Track, client: YMClient?) async {
        let key = track.id.value
        if let cached = cache[key] {
            (lyrics, writers, source) = cached
            return
        }
        lyrics = nil
        source = nil
        guard let client else { return }

        let info = track.lyricsInfo
        var result: (Lyrics, [String]) = (.unavailable, [])
        if info?.hasAvailableSyncLyrics != false,
           let synced = try? await client.lyrics(trackID: key, format: .synced) {
            let lines = LRCParser.parse(synced.text)
            if !lines.isEmpty { result = (.synced(lines), synced.writers) }
        }
        if case .unavailable = result.0, info?.hasAvailableTextLyrics != false,
           let text = try? await client.lyrics(trackID: key, format: .text),
           !text.text.isEmpty {
            result = (.plain(text.text), text.writers)
        }
        var source: String? = nil
        if case .unavailable = result.0, !Task.isCancelled, let fallback = await LRCLib.lyrics(for: track) {
            result = (fallback, [])
            source = "lrclib.net"
        }
        guard !Task.isCancelled else { return }
        cache[key] = (result.0, result.1, source)
        (lyrics, writers, self.source) = (result.0, result.1, source)
    }
}
