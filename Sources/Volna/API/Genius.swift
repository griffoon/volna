import Foundation

/// Artist pages and bios from Genius through the public JSON the site itself uses.
/// Only an exact name match counts, so a namesake never gets linked.
enum Genius {
    struct Artist: Sendable {
        let id: Int
        let url: URL
    }

    private struct SearchResponse: Decodable {
        struct Inner: Decodable { let sections: [Section]? }
        struct Section: Decodable { let hits: [Hit]? }
        struct Hit: Decodable { let result: Result? }
        struct Result: Decodable { let id: Int?; let name: String?; let url: String? }
        let response: Inner?
    }

    private struct ArtistResponse: Decodable {
        struct Inner: Decodable { let artist: Body? }
        struct Body: Decodable { let description: Description? }
        struct Description: Decodable { let plain: String? }
        let response: Inner?
    }

    static func artist(name: String) async -> Artist? {
        var components = URLComponents(string: "https://genius.com/api/search/artist")!
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        guard let decoded: SearchResponse = await fetch(components.url) else { return nil }
        let wanted = normalize(name)
        let hit = decoded.response?.sections?.flatMap { $0.hits ?? [] }.compactMap(\.result)
            .first { normalize($0.name ?? "") == wanted }
        guard let hit, let id = hit.id, let url = hit.url.flatMap(URL.init(string:)) else { return nil }
        return Artist(id: id, url: url)
    }

    /// The artist's bio in plain text (English as a rule), or nil when Genius has none.
    static func bio(artistID: Int) async -> String? {
        let url = URL(string: "https://genius.com/api/artists/\(artistID)?text_format=plain")
        guard let decoded: ArtistResponse = await fetch(url),
              let text = decoded.response?.artist?.description?.plain?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "?" else { return nil }
        return text
    }

    private static func fetch<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Volna/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
