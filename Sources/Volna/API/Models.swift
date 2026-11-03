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

    var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    var fullTitle: String {
        guard let version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }

    var albumID: FlexibleID? { albums?.first?.id }

    var cover: String? { coverUri ?? albums?.first?.coverUri }

    private enum CodingKeys: String, CodingKey {
        case id, title, version, artists, albums, coverUri, durationMs, available, lyricsInfo
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
    }
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
