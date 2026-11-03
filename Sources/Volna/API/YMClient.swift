import CryptoKit
import Foundation

enum YMError: LocalizedError {
    case unauthorized
    case http(Int)
    case noStream
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Сессия истекла, войди заново"
        case .http(let code): "Сервер ответил \(code)"
        case .noStream: "Трек недоступен для прослушивания"
        case .badResponse: "Непонятный ответ сервера"
        }
    }
}

/// Thin client over the unofficial api.music.yandex.net endpoints.
struct YMClient: Sendable {
    static let baseURL = URL(string: "https://api.music.yandex.net")!

    let token: String
    var session: URLSession = .shared

    // MARK: Account

    func accountStatus() async throws -> AccountStatus {
        try await get("account/status")
    }

    // MARK: Library

    func likedTracks(uid: String) async throws -> [TrackShort] {
        let likes: LikesLibrary = try await get("users/\(uid)/likes/tracks")
        return likes.library.tracks
    }

    func tracks(refs: [String]) async throws -> [Track] {
        guard !refs.isEmpty else { return [] }
        return try await post("tracks", form: ["track-ids": refs.joined(separator: ",")])
    }

    func playlists(uid: String) async throws -> [Playlist] {
        try await get("users/\(uid)/playlists/list")
    }

    func playlist(uid: String, kind: String) async throws -> Playlist {
        try await get("users/\(uid)/playlists/\(kind)")
    }

    func album(id: String) async throws -> AlbumWithTracks {
        try await get("albums/\(id)/with-tracks")
    }

    func artistTracks(id: String) async throws -> [Track] {
        let page: ArtistTracks = try await get("artists/\(id)/tracks", query: ["page-size": "50"])
        return page.tracks
    }

    func setLike(_ liked: Bool, trackRef: String, uid: String) async throws {
        let action = liked ? "add-multiple" : "remove"
        let _: AnyDecodable = try await post(
            "users/\(uid)/likes/tracks/\(action)",
            form: ["track-ids": trackRef]
        )
    }

    // MARK: Search

    func search(_ text: String) async throws -> SearchResult {
        try await get("search", query: ["text": text, "type": "all", "page": "0", "nocorrect": "false"])
    }

    // MARK: My Wave

    func waveTracks(after lastTrackID: String?) async throws -> StationBatch {
        var query = ["settings2": "true"]
        if let lastTrackID { query["queue"] = lastTrackID }
        return try await get("rotor/station/user:onyourwave/tracks", query: query)
    }

    // MARK: Streaming

    func downloadInfo(trackID: String) async throws -> [DownloadInfo] {
        try await get("tracks/\(trackID)/download-info")
    }

    // MARK: Artist

    func artistBrief(id: String) async throws -> ArtistBriefInfo {
        try await get("artists/\(id)/brief-info")
    }

    // MARK: Playlists editing

    func addToPlaylist(_ track: Track, uid: String, kind: String) async throws {
        let current = try await playlist(uid: uid, kind: kind)
        var item = ["id": track.id.value]
        if let album = track.albumID { item["albumId"] = album.value }
        let diff = [["op": "insert", "at": 0, "tracks": [item]] as [String: Any]]
        let json = try JSONSerialization.data(withJSONObject: diff)
        let _: AnyDecodable = try await post(
            "users/\(uid)/playlists/\(kind)/change-relative",
            form: ["diff": String(decoding: json, as: UTF8.self), "revision": String(current.revision ?? 1)]
        )
    }

    // MARK: Wave sessions

    func waveSettings() async throws -> WaveSettings {
        try await get("rotor/wave/settings")
    }

    func newWaveSession(seeds: [String], queue: [String] = []) async throws -> RotorSession {
        try await postJSON("rotor/session/new", body: [
            "seeds": seeds,
            "queue": queue,
            "includeTracksInResponse": true,
        ])
    }

    func waveSessionTracks(sessionID: String, queue: [String]) async throws -> RotorSession {
        try await postJSON("rotor/session/\(sessionID)/tracks", body: ["queue": queue])
    }

    enum WaveEvent: Sendable {
        case radioStarted
        case trackStarted(trackID: String)
        case trackFinished(trackID: String, played: Double)
        case skip(trackID: String, played: Double)
    }

    func sendWaveFeedback(sessionID: String, batchID: String?, event: WaveEvent) async throws {
        var payload: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date())]
        switch event {
        case .radioStarted:
            payload["type"] = "radioStarted"
        case .trackStarted(let id):
            payload["type"] = "trackStarted"
            payload["trackId"] = id
        case .trackFinished(let id, let played):
            payload["type"] = "trackFinished"
            payload["trackId"] = id
            payload["totalPlayedSeconds"] = played
        case .skip(let id, let played):
            payload["type"] = "skip"
            payload["trackId"] = id
            payload["totalPlayedSeconds"] = played
        }
        var body: [String: Any] = ["event": payload]
        if let batchID { body["batchId"] = batchID }
        if case .radioStarted = event { body["from"] = "mobile-radio-user-onyourwave" }
        let _: AnyDecodable = try await postJSON("rotor/session/\(sessionID)/feedback", body: body)
    }

    // MARK: Lossless

    /// The desktop app's key; the signature is only accepted together with its client header.
    private static let fileInfoSignKey = SymmetricKey(data: Data("kzqU4XhfCaY6B6JTHODeq5".utf8))
    private static let desktopClient = "YandexMusicDesktopAppWindows/5.95.0"
    static let allCodecs = ["flac", "flac-mp4", "aac-mp4", "he-aac-mp4", "aac", "he-aac", "mp3"]

    func fileInfo(trackID: String, quality: String, transport: String) async throws -> FileInfo.Download {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let codecs = Self.allCodecs
        let message = timestamp + trackID + quality + codecs.joined() + transport
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: Self.fileInfoSignKey)
        let sign = String(Data(mac).base64EncodedString().dropLast())
        let info: FileInfo = try await get(
            "get-file-info",
            query: [
                "ts": timestamp, "trackId": trackID, "quality": quality,
                "codecs": codecs.joined(separator: ","), "transports": transport, "sign": sign,
            ],
            headers: ["X-Yandex-Music-Client": Self.desktopClient]
        )
        return info.downloadInfo
    }

    // MARK: Lyrics

    enum LyricsFormat: String {
        case synced = "LRC"
        case text = "TEXT"
    }

    /// Key the Android app signs lyrics requests with.
    private static let lyricsSignKey = SymmetricKey(data: Data("p93jhgh689SBReK6ghtw62".utf8))

    func lyrics(trackID: String, format: LyricsFormat) async throws -> (text: String, writers: [String]) {
        let numericID = trackID.split(separator: ":").first.map(String.init) ?? trackID
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let mac = HMAC<SHA256>.authenticationCode(for: Data((numericID + timestamp).utf8), using: Self.lyricsSignKey)
        let info: TrackLyrics = try await get(
            "tracks/\(numericID)/lyrics",
            query: ["format": format.rawValue, "timeStamp": timestamp, "sign": Data(mac).base64EncodedString()]
        )
        guard let url = URL(string: info.downloadUrl) else { throw YMError.badResponse }
        let (data, _) = try await session.data(from: url)
        return (String(decoding: data, as: UTF8.self), info.writers ?? [])
    }

    // MARK: Transport

    private func get<T: Decodable>(
        _ path: String, query: [String: String] = [:], headers: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request)
    }

    private func postJSON<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func post<T: Decodable>(_ path: String, form: [String: String]) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if request.value(forHTTPHeaderField: "X-Yandex-Music-Client") == nil {
            request.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YMError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw YMError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw YMError.http(http.statusCode) }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).result
    }
}

/// Accepts any JSON value for endpoints whose result we ignore.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
