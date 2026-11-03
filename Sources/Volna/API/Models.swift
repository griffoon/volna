import Foundation

/// Yandex returns ids as either strings or numbers depending on the endpoint.
struct FlexibleID: Codable, Hashable, Sendable, CustomStringConvertible {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var description: String { value }
}

struct Envelope<T: Decodable>: Decodable {
    let result: T
}

struct Artist: Codable, Hashable, Identifiable, Sendable {
    let id: FlexibleID
    let name: String
    let cover: CoverRef?
}

struct CoverRef: Codable, Hashable, Sendable {
    let uri: String?
}

struct Album: Codable, Hashable, Identifiable, Sendable {
    let id: FlexibleID
    let title: String
    let coverUri: String?
    let year: Int?
    let artists: [Artist]?
    let trackCount: Int?
    /// ISO 8601; in the future for upcoming releases that can be presaved.
    var releaseDate: String? = nil

    var releaseDay: Date? {
        guard let releaseDate else { return nil }
        return ISO8601DateFormatter().date(from: releaseDate)
            ?? (try? Date(String(releaseDate.prefix(10)), strategy: .iso8601.year().month().day()))
    }

    var isUpcoming: Bool { releaseDay.map { $0 > Date() } ?? false }
}

struct Track: Codable, Hashable, Identifiable, Sendable {
    let id: FlexibleID
    let title: String
    let version: String?
    let artists: [Artist]
    let albums: [Album]?
    let coverUri: String?
    let durationMs: Int?
    let available: Bool?
    let lyricsInfo: LyricsInfo?
    /// EBU R128 loudness: integrated LUFS and true peak, for volume normalisation.
    let r128: Loudness?

    var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    var fullTitle: String {
        guard let version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }

    var albumID: FlexibleID? { albums?.first?.id }

    /// Public link that opens in the official app or the web player.
    var shareURL: URL? {
        guard let album = albumID else { return URL(string: "https://music.yandex.ru/track/\(id.value)") }
        return URL(string: "https://music.yandex.ru/album/\(album.value)/track/\(id.value)")
    }

    var cover: String? { coverUri ?? albums?.first?.coverUri }

    private enum CodingKeys: String, CodingKey {
        case id, title, version, artists, albums, coverUri, durationMs, available, lyricsInfo, r128
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(FlexibleID.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Без названия"
        version = try? c.decode(String.self, forKey: .version)
        artists = (try? c.decode([Artist].self, forKey: .artists)) ?? []
        albums = try? c.decode([Album].self, forKey: .albums)
        coverUri = try? c.decode(String.self, forKey: .coverUri)
        durationMs = try? c.decode(Int.self, forKey: .durationMs)
        available = try? c.decode(Bool.self, forKey: .available)
        lyricsInfo = try? c.decode(LyricsInfo.self, forKey: .lyricsInfo)
        r128 = try? c.decode(Loudness.self, forKey: .r128)
    }
}

struct Loudness: Codable, Hashable, Sendable {
    let i: Double?
    let tp: Double?
}

struct LyricsInfo: Codable, Hashable, Sendable {
    let hasAvailableSyncLyrics: Bool?
    let hasAvailableTextLyrics: Bool?
}

struct TrackLyrics: Decodable, Sendable {
    let downloadUrl: String
    let writers: [String]?
}

struct TrackShort: Decodable, Hashable, Sendable {
    let id: FlexibleID
    let albumId: FlexibleID?
    let track: Track?

    /// Form value used by `POST /tracks` and like endpoints.
    var ref: String {
        guard let albumId else { return id.value }
        return "\(id.value):\(albumId.value)"
    }
}

struct Playlist: Decodable, Hashable, Identifiable, Sendable {
    let uid: FlexibleID
    let kind: FlexibleID
    let title: String
    let trackCount: Int?
    let cover: PlaylistCover?
    let ogImage: String?
    let tracks: [TrackShort]?
    let revision: Int?
    let visibility: String?

    var id: String { "\(uid.value):\(kind.value)" }

    var coverURI: String? { cover?.uri ?? cover?.itemsUri?.first ?? ogImage }
}

struct PlaylistCover: Decodable, Hashable, Sendable {
    let uri: String?
    let itemsUri: [String]?
}

struct AccountStatus: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let uid: FlexibleID?
        let login: String?
        let displayName: String?
    }

    struct Plus: Decodable, Sendable {
        let hasPlus: Bool?
    }

    let account: Account
    let plus: Plus?
}

struct LikesLibrary: Decodable, Sendable {
    struct Library: Decodable, Sendable {
        let tracks: [TrackShort]
    }

    let library: Library
}

struct AlbumWithTracks: Decodable, Sendable {
    let id: FlexibleID
    let title: String
    let releaseDate: String?
    let coverUri: String?
    let year: Int?
    let artists: [Artist]?
    let volumes: [[Track]]?

    var tracks: [Track] { volumes?.flatMap { $0 } ?? [] }
}

struct SearchResult: Decodable, Sendable {
    struct Section<T: Decodable & Sendable>: Decodable, Sendable {
        let results: [T]
    }

    let tracks: Section<Track>?
    let albums: Section<Album>?
    let artists: Section<Artist>?
    let playlists: Section<Playlist>?
}

struct ArtistTracks: Decodable, Sendable {
    let tracks: [Track]
}

struct StationBatch: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let track: Track
    }

    let sequence: [Item]
    let batchId: String?
}

struct DownloadInfo: Decodable, Sendable {
    let codec: String
    let bitrateInKbps: Int
    let downloadInfoUrl: String
    let preview: Bool?
}

/// Yandex cover URIs look like `avatars.yandex.net/get-music-content/.../%%`.
enum CoverURL {
    static func make(_ uri: String?, size: Int = 400) -> URL? {
        guard let uri, !uri.isEmpty else { return nil }
        let sized = uri.replacingOccurrences(of: "%%", with: "\(size)x\(size)")
        return URL(string: sized.hasPrefix("http") ? sized : "https://\(sized)")
    }
}

// MARK: - Artist

struct ArtistBriefInfo: Decodable, Sendable {
    let artist: ArtistFull
    let albums: [Album]?
    let alsoAlbums: [Album]?
    let popularTracks: [Track]?
    let similarArtists: [Artist]?
}

struct ArtistFull: Decodable, Sendable {
    let id: FlexibleID
    let name: String
    let cover: CoverRef?
    let genres: [String]?
    let ogImage: String?

    var coverURI: String? { cover?.uri ?? ogImage }
}

// MARK: - My Wave

struct StationID: Decodable, Hashable, Sendable {
    let type: String
    let tag: String

    var seed: String { "\(type):\(tag)" }
}

struct WaveStation: Decodable, Hashable, Sendable {
    let id: StationID
    let name: String
}

struct WaveSettings: Decodable, Sendable {
    struct Block: Decodable, Sendable {
        let type: String?
        let items: [WaveStation]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            items = (try? c.decode([Lenient<WaveStation>].self, forKey: .items))?.compactMap(\.value)
        }

        private enum CodingKeys: String, CodingKey { case type, items }
    }

    struct Option: Decodable, Hashable, Sendable {
        let name: String
        let serializedSeed: String?
        let unspecified: Bool?
    }

    struct Restriction: Decodable, Sendable {
        let possibleValues: [Option]?
    }

    let blocks: [Block]?
    /// Keyed by setting name (`diversity`, `moodEnergy`, `language`, ...).
    let settingRestrictions: [String: Restriction]

    private enum CodingKeys: String, CodingKey { case blocks, settingRestrictions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try? c.decode([Block].self, forKey: .blocks)
        let raw = (try? c.decode([String: Lenient<Restriction>].self, forKey: .settingRestrictions)) ?? [:]
        settingRestrictions = raw.compactMapValues(\.value)
    }
}

/// Decodes a value or swallows the failure, so one odd element doesn't break a whole list.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct RotorSession: Decodable, Sendable {
    let radioSessionId: String?
    let batchId: String?
    let sequence: [StationBatch.Item]?
}

// MARK: - Lossless

struct FileInfo: Decodable, Sendable {
    struct Download: Decodable, Sendable {
        let codec: String
        let bitrate: Int?
        let url: String
        let key: String?
        let transport: String?
    }

    let downloadInfo: Download
}

// MARK: - Home feed

/// `/feed`: generated playlists (Плейлист дня, Дежавю, Премьера, Тайник) and listening-based events.
struct Feed: Decodable, Sendable {
    struct Generated: Decodable, Sendable, Identifiable {
        let type: String
        let ready: Bool?
        let data: Playlist?

        var id: String { type }
    }

    struct Day: Decodable, Sendable {
        let day: String?
        let events: [Event]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try? c.decode(String.self, forKey: .day)
            events = (try? c.decode([Lenient<Event>].self, forKey: .events))?.compactMap(\.value) ?? []
        }

        private enum CodingKeys: String, CodingKey { case day, events }
    }

    struct Event: Decodable, Sendable, Identifiable {
        struct AlbumItem: Decodable, Sendable { let album: Album? }
        struct ArtistItem: Decodable, Sendable { let artist: Artist?; let tracks: [Track]? }

        let id: String
        let type: String
        let title: String?
        let tracks: [Track]
        let albums: [Album]
        let artists: [ArtistItem]

        private enum CodingKeys: String, CodingKey { case id, type, title, tracks, albums, artists }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(FlexibleID.self, forKey: .id).value) ?? UUID().uuidString
            type = (try? c.decode(String.self, forKey: .type)) ?? ""
            // Title is either a plain string or a list of `{type, text}` runs.
            if let plain = try? c.decode(String.self, forKey: .title) {
                title = plain
            } else if let runs = try? c.decode([TitleRun].self, forKey: .title) {
                title = runs.compactMap(\.text).joined()
            } else {
                title = nil
            }
            tracks = (try? c.decode([Lenient<Track>].self, forKey: .tracks))?.compactMap(\.value) ?? []
            albums = ((try? c.decode([Lenient<AlbumItem>].self, forKey: .albums))?.compactMap { $0.value?.album }) ?? []
            artists = (try? c.decode([Lenient<ArtistItem>].self, forKey: .artists))?.compactMap(\.value) ?? []
        }

        private struct TitleRun: Decodable { let text: String? }
    }

    let generatedPlaylists: [Generated]
    let days: [Day]

    private enum CodingKeys: String, CodingKey { case generatedPlaylists, days }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedPlaylists = (try? c.decode([Lenient<Generated>].self, forKey: .generatedPlaylists))?.compactMap(\.value) ?? []
        days = (try? c.decode([Lenient<Day>].self, forKey: .days))?.compactMap(\.value) ?? []
    }
}

struct NewReleases: Decodable, Sendable {
    let newReleases: [FlexibleID]?
}

struct ChartInfo: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Position: Decodable, Sendable {
            let position: Int?
            let shift: Int?
        }

        let track: Track?
        let chart: Position?
    }

    struct ChartPlaylist: Decodable, Sendable {
        let tracks: [Lenient<Entry>]?
    }

    let title: String?
    let chart: ChartPlaylist?

    var entries: [Entry] { chart?.tracks?.compactMap(\.value).filter { $0.track != nil } ?? [] }
}

// MARK: - Listening history

/// `/music-history`: days of play contexts (album, playlist, artist, wave), each with its tracks.
struct MusicHistory: Decodable, Sendable {
    struct Day: Decodable, Sendable {
        let date: String?
        let groups: [Group]

        private enum CodingKeys: String, CodingKey { case date, items }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try? c.decode(String.self, forKey: .date)
            groups = (try? c.decode([Lenient<Group>].self, forKey: .items))?.compactMap(\.value) ?? []
        }
    }

    struct Group: Decodable, Sendable {
        let context: Item?
        let tracks: [Item]

        private enum CodingKeys: String, CodingKey { case context, tracks }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            context = try? c.decode(Item.self, forKey: .context)
            tracks = (try? c.decode([Lenient<Item>].self, forKey: .tracks))?.compactMap(\.value) ?? []
        }
    }

    struct ItemID: Decodable, Sendable {
        let id: FlexibleID?
        let trackId: FlexibleID?
        let albumId: FlexibleID?
        let uid: FlexibleID?
        let kind: FlexibleID?
        let seeds: [String]?
    }

    struct Context: Decodable, Sendable {
        let album: Album?
        let artist: Artist?
        let playlist: Playlist?
        let wave: WaveRef?
    }

    struct WaveRef: Decodable, Sendable {
        let name: String?
        let title: String?
    }

    /// One entry: a track, or the album / playlist / artist / wave it was played from.
    struct Item: Decodable, Sendable {
        let type: String
        let itemID: ItemID?
        let track: Track?
        let context: Context?

        private enum Keys: String, CodingKey { case type, data }
        private enum DataKeys: String, CodingKey { case itemId, fullModel }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = (try? c.decode(String.self, forKey: .type)) ?? ""
            let data = try? c.nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            itemID = try? data?.decode(ItemID.self, forKey: .itemId)
            track = type == "track" ? try? data?.decode(Track.self, forKey: .fullModel) : nil
            context = type == "track" ? nil : try? data?.decode(Context.self, forKey: .fullModel)
        }
    }

    let days: [Day]

    private enum CodingKeys: String, CodingKey { case historyTabs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = (try? c.decode([Lenient<Day>].self, forKey: .historyTabs))?.compactMap(\.value) ?? []
    }
}

// MARK: - Artist extras

/// `artists/{id}/info`: bio and monthly listeners.
struct ArtistAbout: Decodable, Sendable {
    let description: String?
    let monthlyListeners: Int?

    private enum CodingKeys: String, CodingKey { case description, stats }
    private struct Stats: Decodable { let lastMonthListeners: Int? }
    private struct Text: Decodable { let text: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let plain = try? c.decode(String.self, forKey: .description) {
            description = plain
        } else {
            description = (try? c.decode(Text.self, forKey: .description))?.text
        }
        monthlyListeners = (try? c.decode(Stats.self, forKey: .stats))?.lastMonthListeners
    }
}

struct Concert: Decodable, Sendable, Identifiable {
    let id: String
    let concertTitle: String?
    let city: String?
    let place: String?
    let afishaUrl: String?
    let date: Date?

    private enum CodingKeys: String, CodingKey { case id, concertTitle, city, place, afishaUrl, datetime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(FlexibleID.self, forKey: .id).value) ?? UUID().uuidString
        concertTitle = try? c.decode(String.self, forKey: .concertTitle)
        city = try? c.decode(String.self, forKey: .city)
        place = try? c.decode(String.self, forKey: .place)
        afishaUrl = try? c.decode(String.self, forKey: .afishaUrl)
        let raw = try? c.decode(String.self, forKey: .datetime)
        date = raw.flatMap { ISO8601DateFormatter().date(from: $0) ?? Concert.plain.date(from: $0) }
    }

    /// Some concerts come without a zone: `2026-12-05T19:00:00`.
    private static let plain: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

// MARK: - Pins

/// Something pinned to the top of the collection in the official apps.
struct Pin: Decodable, Sendable, Identifiable {
    struct Data: Decodable, Sendable {
        let id: FlexibleID?
        let uid: FlexibleID?
        let kind: FlexibleID?
        let name: String?
        let title: String?
        let cover: PlaylistCover?
    }

    let type: String
    let data: Data?

    var id: String { Pin.key(type: type, data: data) }
    var displayTitle: String { data?.title ?? data?.name ?? "" }
    var coverURI: String? { data?.cover?.uri ?? data?.cover?.itemsUri?.first }

    static func key(type: String, data: Data?) -> String {
        switch type {
        case "playlist": "playlist:\(data?.uid?.value ?? ""):\(data?.kind?.value ?? "")"
        default: "\(type):\(data?.id?.value ?? "")"
        }
    }
}

// MARK: - Browse (metatags)

/// `landing3/metatags`: trees of genres, moods, activities and eras.
struct MetatagTrees: Decodable, Sendable {
    struct Leaf: Decodable, Sendable, Hashable {
        let tag: String?
        let title: String?
    }

    struct Tree: Decodable, Sendable {
        let title: String?
        let leaves: [Leaf]

        private enum CodingKeys: String, CodingKey { case title, leaves }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decode(String.self, forKey: .title)
            leaves = (try? c.decode([Lenient<Leaf>].self, forKey: .leaves))?.compactMap(\.value)
                .filter { $0.tag != nil && $0.title != nil } ?? []
        }
    }

    let trees: [Tree]

    private enum CodingKeys: String, CodingKey { case trees }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trees = (try? c.decode([Lenient<Tree>].self, forKey: .trees))?.compactMap(\.value) ?? []
    }
}

/// `metatags/{tag}`: one genre or mood with its playlists, albums and artists.
struct Metatag: Decodable, Sendable {
    struct Title: Decodable, Sendable { let title: String?; let fullTitle: String? }

    let title: Title?
    let stationId: String?
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]

    private enum CodingKeys: String, CodingKey { case title, stationId, artists, albums, playlists }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decode(Title.self, forKey: .title)
        stationId = try? c.decode(String.self, forKey: .stationId)
        artists = (try? c.decode([Lenient<Artist>].self, forKey: .artists))?.compactMap(\.value) ?? []
        albums = (try? c.decode([Lenient<Album>].self, forKey: .albums))?.compactMap(\.value) ?? []
        playlists = (try? c.decode([Lenient<Playlist>].self, forKey: .playlists))?.compactMap(\.value) ?? []
    }
}
