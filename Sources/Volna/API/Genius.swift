import Foundation

/// Finds an artist's page on Genius through the public search the site itself uses.
/// Only an exact name match counts, so a namesake never gets linked.
enum Genius {
    private struct Response: Decodable {
        struct Inner: Decodable { let sections: [Section]? }
        struct Section: Decodable { let hits: [Hit]? }
        struct Hit: Decodable { let result: Result? }
        struct Result: Decodable { let name: String?; let url: String? }
        let response: Inner?
    }

    static func artistPage(name: String) async -> URL? {
        var components = URLComponents(string: "https://genius.com/api/search/artist")!
        components.queryItems = [URLQueryItem(name: "q", value: name)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Volna/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let wanted = normalize(name)
        let hit = decoded.response?.sections?.flatMap { $0.hits ?? [] }.compactMap(\.result)
            .first { normalize($0.name ?? "") == wanted }
        return hit?.url.flatMap(URL.init(string:))
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
