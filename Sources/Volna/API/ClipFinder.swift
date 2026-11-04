import Foundation
import Observation

/// Finds the music video for a track, best source first:
/// Yandex's own clip (plays in the app) → the YouTube video Yandex links to → the actual video
/// found by searching YouTube → just a YouTube search.
@MainActor
@Observable
final class ClipFinder {
    enum Result: Equatable {
        case yandex(YMClient.Clip)
        case video(URL, title: String?)
        case search(URL)

        /// A real video was found, not just a search to try.
        var isFound: Bool { if case .search = self { false } else { true } }
    }

    static let shared = ClipFinder()

    private(set) var results: [String: Result] = [:]
    private var inFlight: Set<String> = []

    func result(for track: Track) -> Result? { results[track.id.value] }

    func resolve(_ track: Track, client: YMClient?) async {
        let key = track.id.value
        guard results[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        if let client {
            let ids = await client.clipIDs(for: track)
            if let clip = (try? await client.clips(ids: ids))?.first(where: { $0.streamURL != nil }) {
                results[key] = .yandex(clip)
                return
            }
            if let video = (try? await client.videos(trackID: key))?.first, let link = video.link {
                results[key] = .video(link, title: video.title)
                return
            }
        }
        if let found = await YouTubeSearch.firstVideo(artist: track.artists.first?.name ?? "", title: track.title) {
            results[key] = .video(found.url, title: found.title)
            return
        }
        results[key] = .search(YouTubeSearch.searchURL(artist: track.artistLine, title: track.fullTitle))
    }
}

/// Looks up a track's video on YouTube without an API key, by reading the search results page.
/// A hit only counts when its title mentions the track's name, so random uploads don't slip in.
enum YouTubeSearch {
    struct Video {
        let url: URL
        let title: String
    }

    static func searchURL(artist: String, title: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: "\(artist) \(title)")]
        return components.url!
    }

    nonisolated(unsafe) private static let renderer =
        #/"videoRenderer":\{"videoId":"([A-Za-z0-9_-]{11})".{0,2000}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"/#

    static func firstVideo(artist: String, title: String) async -> Video? {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "\(artist) \(title) official video"),
            // Videos only, no channels or playlists.
            URLQueryItem(name: "sp", value: "EgIQAQ=="),
            URLQueryItem(name: "hl", value: "ru"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data, as: UTF8.self)

        let wanted = normalize(title)
        guard !wanted.isEmpty else { return nil }
        // Look at the first few results and take the first whose title names the track.
        for match in html.matches(of: renderer).prefix(5) {
            let id = String(match.1)
            let videoTitle = unescape(String(match.2))
            guard normalize(videoTitle).contains(wanted),
                  let link = URL(string: "https://youtu.be/\(id)") else { continue }
            return Video(url: link, title: videoTitle)
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func unescape(_ s: String) -> String {
        guard let data = "\"\(s)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else { return s }
        return decoded
    }
}
