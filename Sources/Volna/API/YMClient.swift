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

    func searchSuggestions(_ part: String) async throws -> [String] {
        struct Suggestions: Decodable { let suggestions: [String]? }
        let result: Suggestions = try await get("search/suggest", query: ["part": part])
        return result.suggestions ?? []
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

    // MARK: Last wave

    struct LastWave: Decodable, Sendable {
        let name: String?
        let seeds: [String]?
    }

    /// The wave this account played last on any device.
    func lastWave() async throws -> LastWave {
        try await get("rotor/wave/last")
    }

    // MARK: Playlist management

    func createPlaylist(title: String, uid: String, isPublic: Bool) async throws -> Playlist {
        try await post("users/\(uid)/playlists/create",
                       form: ["title": title, "visibility": isPublic ? "public" : "private"])
    }

    func deletePlaylist(kind: String, uid: String) async throws {
        let _: AnyDecodable = try await post("users/\(uid)/playlists/\(kind)/delete", form: [:])
    }

    func renamePlaylist(kind: String, uid: String, title: String) async throws -> Playlist {
        try await post("users/\(uid)/playlists/\(kind)/name", form: ["value": title])
    }

    func setPlaylistVisibility(kind: String, uid: String, isPublic: Bool) async throws -> Playlist {
        try await post("users/\(uid)/playlists/\(kind)/visibility", form: ["value": isPublic ? "public" : "private"])
    }

    /// Removes the track at `index`; `revision` must be the playlist's current one.
    func removeFromPlaylist(kind: String, uid: String, index: Int, revision: Int) async throws -> Playlist {
        let diff = [["op": "delete", "from": index, "to": index + 1] as [String: Any]]
        let json = try JSONSerialization.data(withJSONObject: diff)
        return try await post("users/\(uid)/playlists/\(kind)/change", form: [
            "kind": kind, "revision": String(revision), "diff": String(decoding: json, as: UTF8.self),
        ])
    }

    // MARK: Credits

    struct Credit: Decodable, Sendable, Hashable {
        let title: String?
        let value: String?
    }

    /// Writers, producers and the like, as Yandex lists them for the track.
    func credits(trackID: String) async throws -> [Credit] {
        struct Credits: Decodable { let credits: [Lenient<Credit>]? }
        let result: Credits = try await get("tracks/\(trackID)/credits")
        return result.credits?.compactMap(\.value) ?? []
    }

    // MARK: Similar

    func similarTracks(trackID: String) async throws -> [Track] {
        struct Similar: Decodable { let similarTracks: [Lenient<Track>]? }
        let result: Similar = try await get("tracks/\(trackID)/similar")
        return result.similarTracks?.compactMap(\.value) ?? []
    }

    // MARK: History

    /// `fullModels` asks the server to inline full track/album objects for the newest entries.
    func musicHistory(fullModels: Int = 100) async throws -> MusicHistory {
        try await get("music-history", query: ["fullModelsCount": String(fullModels)])
    }

    // MARK: Home

    func feed() async throws -> Feed {
        try await get("feed")
    }

    func newReleaseIDs() async throws -> [String] {
        let list: NewReleases = try await get("landing3/new-releases")
        return list.newReleases?.map(\.value) ?? []
    }

    func albums(ids: [String]) async throws -> [Album] {
        guard !ids.isEmpty else { return [] }
        return try await post("albums", form: ["album-ids": ids.joined(separator: ",")])
    }

    func chart() async throws -> ChartInfo {
        try await get("landing3/chart")
    }

    // MARK: Artist

    func artistBrief(id: String) async throws -> ArtistBriefInfo {
        try await get("artists/\(id)/brief-info")
    }

    func artistAbout(id: String) async throws -> ArtistAbout {
        try await get("artists/\(id)/info")
    }

    /// The artist's own releases, newest first.
    func artistDiscography(id: String) async throws -> [Album] {
        struct Page: Decodable { let albums: [Lenient<Album>]? }
        let page: Page = try await get("artists/\(id)/direct-albums",
                                       query: ["page": "0", "page-size": "100", "sort-by": "year"])
        return page.albums?.compactMap(\.value) ?? []
    }

    func artistConcerts(id: String) async throws -> [Concert] {
        struct Concerts: Decodable { let concerts: [Lenient<Concert>]? }
        let result: Concerts = try await get("artists/\(id)/concerts")
        return result.concerts?.compactMap(\.value) ?? []
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
        case like(trackID: String)
        case dislike(trackID: String)

        var name: String {
            switch self {
            case .radioStarted: "radioStarted"
            case .trackStarted: "trackStarted"
            case .trackFinished: "trackFinished"
            case .skip: "skip"
            case .like: "like"
            case .dislike: "dislike"
            }
        }
    }

    /// `from` value of the mobile app's My Wave, as MarshalX documents it.
    static let waveFrom = "radio-mobile-user-onyourwave"

    /// ISO 8601 with milliseconds and `Z`, the format the rotor and play-audio endpoints expect.
    static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    func sendWaveFeedback(sessionID: String, batchID: String?, event: WaveEvent) async throws {
        var payload: [String: Any] = ["type": event.name, "timestamp": Self.isoNow()]
        switch event {
        case .radioStarted:
            break
        case .trackStarted(let id), .like(let id), .dislike(let id):
            payload["trackId"] = id
        case .trackFinished(let id, let played), .skip(let id, let played):
            payload["trackId"] = id
            payload["totalPlayedSeconds"] = (played * 10).rounded() / 10
        }
        var body: [String: Any] = ["event": payload]
        if let batchID { body["batchId"] = batchID }
        if case .radioStarted = event { body["from"] = Self.waveFrom }
        let _: AnyDecodable = try await postJSON("rotor/session/\(sessionID)/feedback", body: body)
    }

    // MARK: Listening history

    /// Reports a listen. This is what puts tracks into history and teaches recommendations.
    func playAudio(track: Track, uid: String, from: String, playID: String,
                   played: Double, position: Double) async throws {
        let length = Double(track.durationMs ?? 0) / 1000
        var form: [String: String] = [
            "track-id": track.id.value,
            "from-cache": "False",
            "from": from,
            "play-id": playID,
            "uid": uid,
            "timestamp": Self.isoNow(),
            "track-length-seconds": String(Int(length.rounded())),
            "total-played-seconds": String(format: "%.1f", played),
            "end-position-seconds": String(format: "%.1f", position),
            "client-now": Self.isoNow(),
        ]
        if let album = track.albumID { form["album-id"] = album.value }
        let _: AnyDecodable = try await post("play-audio", form: form)
    }

    func likedAlbumIDs(uid: String) async throws -> [String] {
        struct Like: Decodable { let album: Album?; let id: FlexibleID? }
        let likes: [Lenient<Like>] = try await get("users/\(uid)/likes/albums")
        return likes.compactMap { $0.value?.album?.id.value ?? $0.value?.id?.value }
    }

    func setAlbumLike(_ liked: Bool, albumID: String, uid: String) async throws {
        let action = liked ? "add-multiple" : "remove"
        let _: AnyDecodable = try await post("users/\(uid)/likes/albums/\(action)", form: ["album-ids": albumID])
    }

    func setDislike(_ disliked: Bool, trackRef: String, uid: String) async throws {
        let action = disliked ? "add-multiple" : "remove"
        let _: AnyDecodable = try await post(
            "users/\(uid)/dislikes/tracks/\(action)",
            form: ["track-ids": trackRef]
        )
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
