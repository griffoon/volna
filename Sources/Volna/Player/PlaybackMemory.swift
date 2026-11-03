import Foundation

/// The queue and position on disk, so a relaunch picks up where playback stopped.
enum PlaybackMemory {
    struct Snapshot: Codable {
        let tracks: [Track]
        let index: Int
        let position: Double
    }

    /// Long queues (My Wave runs, big playlists) are trimmed around the current track.
    private static let keepBefore = 20
    private static let keepAfter = 180

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "playback.json")
    }

    static func save(tracks: [Track], index: Int, position: Double) {
        let start = max(0, index - keepBefore)
        let end = min(tracks.count, index + keepAfter)
        let snapshot = Snapshot(tracks: Array(tracks[start..<end]), index: index - start, position: position)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
