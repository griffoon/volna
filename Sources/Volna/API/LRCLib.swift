import Foundation

/// Fallback lyrics from LRCLIB (lrclib.net), an open community database with a public API meant
/// for players. Used only when Yandex has no text for a track; often has time-synced lines.
enum LRCLib {
    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let base = URL(string: "https://lrclib.net/api/")!
    /// A search hit counts only if its length is this close to ours, so remixes and live cuts
    /// with a different timing don't get matched.
    private static let durationTolerance = 4.0

    static func lyrics(for track: Track) async -> Lyrics? {
        let artist = track.artists.first?.name ?? ""
        let duration = track.durationMs.map { Double($0) / 1000 }
        guard !artist.isEmpty else { return nil }

        // Exact match first (title, artist, album, length), then a looser search.
        var exact = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album = track.albums?.first?.title, !album.isEmpty { exact.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { exact.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        if let record: Record = await fetch("get", exact), let lyrics = convert(record) {
            return lyrics
        }

        let search = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: artist)]
        guard let hits: [Record] = await fetch("search", search) else { return nil }
        let close = hits.filter { hit in
            guard let duration, let other = hit.duration else { return true }
            return abs(other - duration) <= durationTolerance
        }
        // Prefer a synced hit, then any with text.
        let ordered = close.filter { $0.syncedLyrics?.isEmpty == false } + close
        return ordered.lazy.compactMap(convert).first
    }

    private static func convert(_ record: Record) -> Lyrics? {
        if record.instrumental == true { return nil }
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .plain(plain)
        }
        return nil
    }

    private static func fetch<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async -> T? {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        // LRCLIB asks clients to identify themselves.
        request.setValue("Volna/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
