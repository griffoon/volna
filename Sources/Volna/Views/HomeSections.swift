import SwiftUI

/// Everything below the tunnel on the Wave tab: generated playlists, news from followed
/// artists, new releases and the chart. Sections that fail or come back empty are hidden.
struct HomeSections: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @State private var generated: [Playlist] = []
    @State private var events: [Feed.Event] = []
    @State private var releases: [Album] = []
    @State private var chart: [Track] = []
    @State private var loaded = false
    @State private var loading = false

    /// How much of each feed to show before it turns into noise.
    private static let maxEvents = 4
    private static let maxReleases = 15
    private static let chartLength = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack {
                Text("> рекомендации")
                    .font(Brand.mono(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label(loading ? "обновляю…" : "обновить", systemImage: "arrow.clockwise")
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(Brand.acid)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .overlay(Capsule().stroke(Brand.acid.opacity(0.6), lineWidth: 1))
                        .symbolEffect(.rotate, value: loading)
                }
                .disabled(loading)
            }
            .padding(.horizontal, 20)

            if !generated.isEmpty {
                shelf("собрано для тебя") {
                    ForEach(generated) { playlist in
                        NavigationLink { PlaylistView(playlist: playlist) } label: {
                            PlaylistCard(playlist: playlist)
                        }
                    }
                }
            }

            ForEach(events) { event in
                if !event.albums.isEmpty {
                    shelf(event.title?.lowercased() ?? "новое у твоих артистов") {
                        ForEach(event.albums) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                        }
                    }
                } else if !event.tracks.isEmpty {
                    trackBlock(event.title?.lowercased() ?? "для тебя", tracks: Array(event.tracks.prefix(5)))
                } else if !event.artists.isEmpty {
                    shelf(event.title?.lowercased() ?? "артисты") {
                        ForEach(Array(event.artists.enumerated()), id: \.offset) { _, item in
                            if let artist = item.artist {
                                NavigationLink {
                                    ArtistView(artistID: artist.id.value, name: artist.name)
                                } label: { ArtistCard(artist: artist) }
                            }
                        }
                    }
                }
            }

            if !releases.isEmpty {
                shelf("новые релизы") {
                    ForEach(releases) { album in
                        NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                    }
                }
            }

            if !chart.isEmpty {
                trackBlock("чарт · топ \(chart.count)", tracks: chart, numbered: true)
            }

            if loaded && generated.isEmpty && events.isEmpty && releases.isEmpty && chart.isEmpty {
                Text("> подборки не загрузились")
                    .font(Brand.mono(12))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 120)
        .buttonStyle(.plain)
        .task { await load() }
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TerminalLabel(text: title).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private func trackBlock(_ title: String, tracks: [Track], numbered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TerminalLabel(text: title)
            ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                Button {
                    player.play(tracks, startAt: offset)
                } label: {
                    TrackRow(track: track, number: numbered ? offset + 1 : nil)
                }
                .contextMenu { TrackMenu(track: track) }
            }
        }
        .padding(.horizontal, 20)
    }

    private func load() async {
        guard !loaded, let client = session.client else { return }
        async let feed = try? client.feed()
        async let releaseIDs = try? client.newReleaseIDs()
        async let chartInfo = try? client.chart()

        if let feed = await feed {
            generated = feed.generatedPlaylists.filter { $0.ready != false }.compactMap(\.data)
            events = Array(feed.days.flatMap(\.events)
                .filter { !$0.albums.isEmpty || !$0.tracks.isEmpty || !$0.artists.isEmpty }
                .prefix(Self.maxEvents))
        }
        if let ids = await releaseIDs {
            releases = (try? await client.albums(ids: Array(ids.prefix(Self.maxReleases)))) ?? []
        }
        if let info = await chartInfo {
            chart = Array(info.entries.compactMap(\.track).prefix(Self.chartLength))
        }
        loaded = true
    }

    private func reload() async {
        loading = true
        loaded = false
        await load()
        loading = false
    }
}

private struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImage(uri: playlist.coverURI, size: 400)
                .grayscale(1)
                .contrast(1.1)
                .frame(width: 156, height: 156)
                .overlay(alignment: .bottomLeading) {
                    Text(playlist.trackCount.map { "[\($0) трк]" } ?? "")
                        .font(Brand.mono(10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.75))
                        .foregroundStyle(Brand.acid)
                        .padding(6)
                }
            Text(playlist.title)
                .font(Brand.display(15))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(width: 156, alignment: .leading)
    }
}

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(uri: album.coverUri, size: 300)
                .frame(width: 132, height: 132)
            Text(album.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text((album.artists?.first?.name ?? "").lowercased())
                .font(Brand.mono(11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(width: 132, alignment: .leading)
    }
}

struct ArtistCard: View {
    let artist: Artist

    var body: some View {
        VStack(spacing: 8) {
            CoverImage(uri: artist.cover?.uri, size: 200, corner: 60)
                .frame(width: 104, height: 104)
            Text(artist.name.lowercased())
                .font(Brand.mono(12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(width: 110)
    }
}
