import SwiftUI

/// Genres, moods, activities and eras, shown in search while the field is empty.
struct BrowseSection: View {
    @Environment(Session.self) private var session
    @State private var trees: [MetatagTrees.Tree] = []

    var body: some View {
        ForEach(Array(trees.enumerated()), id: \.offset) { _, tree in
            Section {
                ChipFlow(spacing: 8) {
                    ForEach(tree.leaves, id: \.self) { leaf in
                        NavigationLink {
                            MetatagView(tag: leaf.tag ?? "", title: leaf.title ?? "")
                        } label: {
                            Text((leaf.title ?? "").lowercased())
                                .font(Brand.mono(12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .terminalRow()
            } header: {
                TerminalLabel(text: (tree.title ?? "обзор").lowercased())
            }
        }
        .task {
            guard trees.isEmpty, let client = session.client,
                  let loaded = try? await client.metatagTrees() else { return }
            trees = loaded.trees.filter { !$0.leaves.isEmpty }
        }
    }
}

/// One genre or mood: its wave, playlists, albums and artists.
struct MetatagView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    let tag: String
    let title: String
    @State private var metatag: Metatag?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    TerminalHeader(title: metatag?.title?.fullTitle ?? metatag?.title?.title ?? title, caption: "tag: \(tag)")
                    if let station = metatag?.stationId {
                        Button {
                            Haptics.launch()
                            player.startWave(seeds: [station], title: title)
                        } label: {
                            Label("ВОЛНА: \(title.uppercased())", systemImage: "dot.radiowaves.left.and.right")
                                .font(Brand.mono(13, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .foregroundStyle(Brand.ink)
                                .background(Brand.acid, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .terminalRow()
            .listRowSeparator(.hidden)

            if let playlists = metatag?.playlists, !playlists.isEmpty {
                Section(header: TerminalLabel(text: "плейлисты")) {
                    shelf {
                        ForEach(playlists) { playlist in
                            NavigationLink { PlaylistView(playlist: playlist) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverImage(uri: playlist.coverURI, size: 300).frame(width: 132, height: 132)
                                    Text(playlist.title).font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white).lineLimit(2)
                                }
                                .frame(width: 132, alignment: .leading)
                            }
                        }
                    }
                }
            }
            if let albums = metatag?.albums, !albums.isEmpty {
                Section(header: TerminalLabel(text: "альбомы")) {
                    shelf {
                        ForEach(albums) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                        }
                    }
                }
            }
            if let artists = metatag?.artists, !artists.isEmpty {
                Section(header: TerminalLabel(text: "артисты")) {
                    shelf {
                        ForEach(artists) { artist in
                            NavigationLink {
                                ArtistView(artistID: artist.id.value, name: artist.name)
                            } label: { ArtistCard(artist: artist) }
                        }
                    }
                }
            }
        }
        .terminalPage()
        .overlay {
            if metatag == nil, error == nil { ProgressView().tint(Brand.acid) }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func shelf<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) { content() }
        }
        .scrollIndicators(.hidden)
        .buttonStyle(.plain)
        .terminalRow()
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            metatag = try await client.metatag(tag)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
