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
    @State private var fullChart: [Track] = []
    @State private var recent: [RecentContext] = []
    @State private var loaded = false
    @State private var loading = false
    /// Titles of shelves the user folded away, one per line.
    @AppStorage("homeCollapsed") private var collapsedRaw = ""

    /// How much of each feed to show before it turns into noise.
    private static let maxEvents = 4
    private static let maxReleases = 15
    private static let chartLength = 10
    private static let maxRecent = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack {
                Text("> рекомендации")
                    .font(Brand.mono(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button {
                    Haptics.tap(); Task { await reload(); Haptics.success() }
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

            if !recent.isEmpty {
                shelf("недавно слушал", open: { HistoryView() }) {
                    ForEach(recent) { context in
                        RecentContextLink(context: context) { RecentCard(context: context) }
                    }
                }
            }

            if !generated.isEmpty {
                shelf("собрано для тебя", open: {
                    ShelfGridView(title: "Собрано для тебя", caption: "feed | generated", items: generated) { playlist in
                        NavigationLink { PlaylistView(playlist: playlist) } label: { PlaylistCard(playlist: playlist) }
                    }
                }) {
                    ForEach(generated) { playlist in
                        NavigationLink { PlaylistView(playlist: playlist) } label: {
                            PlaylistCard(playlist: playlist)
                        }
                    }
                }
            }

            ForEach(events) { event in
                if !event.albums.isEmpty {
                    shelf(event.title?.lowercased() ?? "новое у твоих артистов", open: {
                        ShelfGridView(title: event.title ?? "Новое у твоих артистов", items: event.albums) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                        }
                    }) {
                        ForEach(event.albums) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                        }
                    }
                } else if !event.tracks.isEmpty {
                    trackBlock(event.title?.lowercased() ?? "для тебя", tracks: Array(event.tracks.prefix(5)),
                               open: { ShelfTracksView(title: event.title ?? "Для тебя", tracks: event.tracks) })
                } else if !event.artists.isEmpty {
                    shelf(event.title?.lowercased() ?? "артисты", open: {
                        ShelfGridView(title: event.title ?? "Артисты", items: event.artists.compactMap(\.artist)) { artist in
                            NavigationLink { ArtistView(artistID: artist.id.value, name: artist.name) } label: { ArtistCard(artist: artist) }
                        }
                    }) {
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
                shelf("новые релизы", open: { ReleasesFullView() }) {
                    ForEach(releases) { album in
                        NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                    }
                }
            }

            if !chart.isEmpty {
                trackBlock("чарт", tracks: chart, numbered: true,
                           open: { ShelfTracksView(title: "Чарт", caption: "топ \(fullChart.count)", tracks: fullChart, numbered: true) })
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

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    private func toggleCollapsed(_ title: String) {
        var set = collapsed
        if set.contains(title) { set.remove(title) } else { set.insert(title) }
        collapsedRaw = set.sorted().joined(separator: "\n")
    }

    /// Section title: tapping the name opens the whole list full screen, the chevron folds
    /// the shelf away like a spoiler (remembered across launches).
    private func header<Destination: View>(_ title: String, @ViewBuilder open: () -> Destination) -> some View {
        let isCollapsed = collapsed.contains(title)
        return HStack(spacing: 8) {
            NavigationLink { open() } label: {
                HStack(spacing: 6) {
                    TerminalLabel(text: title)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Brand.acid.opacity(0.8))
                }
                .opacity(isCollapsed ? 0.5 : 1)
                .contentShape(.rect)
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            .accessibilityHint("Открыть весь список")
            Spacer(minLength: 0)
            Button {
                Haptics.tick()
                withAnimation(.snappy) { toggleCollapsed(title) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 36, height: 28)
                    .contentShape(.rect)
            }
            .accessibilityLabel(isCollapsed ? "Развернуть: \(title)" : "Свернуть: \(title)")
        }
    }

    private func shelf<Content: View, Destination: View>(
        _ title: String, @ViewBuilder open: () -> Destination, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(title, open: open).padding(.horizontal, 20)
            if !collapsed.contains(title) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) { content() }
                        .padding(.horizontal, 20)
                        .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func trackBlock<Destination: View>(
        _ title: String, tracks: [Track], numbered: Bool = false, @ViewBuilder open: () -> Destination
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title, open: open)
            if !collapsed.contains(title) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                    Button {
                        player.play(tracks, startAt: offset)
                    } label: {
                        TrackRow(track: track, number: numbered ? offset + 1 : nil)
                    }
                    .contextMenu { TrackMenu(track: track) }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func load() async {
        guard !loaded, let client = session.client else { return }
        async let feed = try? client.feed()
        async let releaseIDs = try? client.newReleaseIDs()
        async let chartInfo = try? client.chart()
        async let history = try? client.musicHistory(fullModels: 30)

        if let feed = await feed {
            generated = feed.generatedPlaylists.filter { $0.ready != false }.compactMap(\.data)
            events = Array(feed.days.flatMap(\.events)
                .filter { !$0.albums.isEmpty || !$0.tracks.isEmpty || !$0.artists.isEmpty }
                .prefix(Self.maxEvents))
        }
        if let ids = await releaseIDs {
            releases = (try? await client.albums(ids: Array(ids.prefix(Self.maxReleases)))) ?? []
            ReleasesFeed.shared.prime(ids: ids, albums: releases)
        }
        if let info = await chartInfo {
            fullChart = info.entries.compactMap(\.track)
            chart = Array(fullChart.prefix(Self.chartLength))
        }
        if let history = await history {
            var seen = Set<String>()
            recent = history.days.flatMap(\.groups).compactMap { $0.context.flatMap(RecentContext.init) }
                .filter { seen.insert($0.id).inserted }
                .prefix(Self.maxRecent).map { $0 }
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
