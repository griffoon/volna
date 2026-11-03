import SwiftUI

/// What was played from, distilled from `/music-history` for cards and headers.
struct RecentContext: Identifiable {
    enum Target {
        case album(Album)
        case playlist(Playlist)
        case artist(Artist)
        case wave(seeds: [String], name: String)
    }

    let id: String
    let target: Target
    let title: String
    let kind: String
    let coverURI: String?

    init?(_ item: MusicHistory.Item) {
        let ctx = item.context
        switch item.type {
        case "album":
            guard let album = ctx?.album else { return nil }
            target = .album(album); title = album.title; kind = "альбом"; coverURI = album.coverUri
            id = "album-\(album.id.value)"
        case "playlist":
            guard let playlist = ctx?.playlist else { return nil }
            target = .playlist(playlist); title = playlist.title; kind = "плейлист"; coverURI = playlist.coverURI
            id = "playlist-\(playlist.id)"
        case "artist":
            guard let artist = ctx?.artist else { return nil }
            target = .artist(artist); title = artist.name; kind = "артист"; coverURI = artist.cover?.uri
            id = "artist-\(artist.id.value)"
        case "wave":
            guard let seeds = item.itemID?.seeds, !seeds.isEmpty else { return nil }
            let name = ctx?.wave?.name ?? ctx?.wave?.title ?? "Волна"
            target = .wave(seeds: seeds, name: name); title = name; kind = "волна"; coverURI = nil
            id = "wave-\(seeds.joined(separator: ","))"
        default:
            return nil
        }
    }
}

/// Opens a recent context: a page for albums, playlists and artists, playback for waves.
struct RecentContextLink<Label: View>: View {
    @Environment(PlayerEngine.self) private var player
    let context: RecentContext
    @ViewBuilder let label: () -> Label

    var body: some View {
        switch context.target {
        case .album(let album):
            NavigationLink { AlbumView(album: album) } label: { label() }
        case .playlist(let playlist):
            NavigationLink { PlaylistView(playlist: playlist) } label: { label() }
        case .artist(let artist):
            NavigationLink { ArtistView(artistID: artist.id.value, name: artist.name) } label: { label() }
        case .wave(let seeds, let name):
            Button {
                Haptics.launch()
                player.startWave(seeds: seeds, title: name)
            } label: { label() }
        }
    }
}

struct RecentCard: View {
    let context: RecentContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let uri = context.coverURI {
                    CoverImage(uri: uri, size: 300, corner: context.kind == "артист" ? 60 : 3)
                } else {
                    ZStack {
                        Rectangle().fill(Brand.acid.opacity(0.15))
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Brand.acid)
                    }
                    .clipShape(.rect(cornerRadius: 3))
                }
            }
            .frame(width: 120, height: 120)
            Text(context.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("> \(context.kind)")
                .font(Brand.mono(11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 120, alignment: .leading)
    }
}

/// Full listening history, newest day first, grouped by what each run was played from.
struct HistoryView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @State private var days: [MusicHistory.Day] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            TerminalHeader(title: "История", caption: "music-history")
                .terminalRow()
                .listRowSeparator(.hidden)

            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                Section {
                    ForEach(Array(day.groups.enumerated()), id: \.offset) { _, group in
                        let tracks = group.tracks.compactMap(\.track)
                        if let context = group.context.flatMap(RecentContext.init) {
                            RecentContextLink(context: context) {
                                Text("// \(context.kind): \(context.title.lowercased())")
                                    .font(Brand.mono(11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .terminalRow()
                        }
                        ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                            Button {
                                Haptics.tap()
                                player.play(tracks, startAt: offset)
                            } label: {
                                TrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenu(track: track) }
                            .terminalRow()
                        }
                    }
                } header: {
                    TerminalLabel(text: Self.dayTitle(day.date))
                }
            }
        }
        .terminalPage()
        .overlay {
            if !loaded { ProgressView().tint(Brand.acid) }
            if loaded && days.isEmpty && error == nil {
                Text("> история пуста").font(Brand.mono(12)).foregroundStyle(.white.opacity(0.5))
            }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            days = try await client.musicHistory().days
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// `2026-11-03` → `сегодня` / `вчера` / `3 ноября`.
    static func dayTitle(_ raw: String?) -> String {
        guard let raw, let date = try? Date(raw, strategy: .iso8601.year().month().day()) else { return raw ?? "" }
        if Calendar.current.isDateInToday(date) { return "сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "вчера" }
        return date.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU")))
    }
}
