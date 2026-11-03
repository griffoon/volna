import SwiftUI

struct ArtistView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    let artistID: String
    let name: String
    @State private var info: ArtistBriefInfo?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let tracks = info?.popularTracks, !tracks.isEmpty {
                Section("Популярное") {
                    TrackList(tracks: Array(tracks.prefix(10)))
                }
            }

            albumShelf("Альбомы", info?.albums)
            albumShelf("Сборники и участие", info?.alsoAlbums)

            if let similar = info?.similarArtists, !similar.isEmpty {
                Section("Похожие") {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(similar.prefix(15)) { artist in
                                NavigationLink {
                                    ArtistView(artistID: artist.id.value, name: artist.name)
                                } label: {
                                    VStack(spacing: 6) {
                                        CoverImage(uri: artist.cover?.uri, size: 200, corner: 50)
                                            .frame(width: 96)
                                        Text(artist.name).font(.footnote).lineLimit(1)
                                    }
                                    .frame(width: 100)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if info == nil, error == nil { ProgressView() }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(uri: info?.artist.coverURI, size: 800, corner: 0)
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 12) {
                Text(info?.artist.name ?? name)
                    .font(.system(size: 38, weight: .heavy))
                    .foregroundStyle(.white)
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            player.play(info?.popularTracks ?? [])
                        } label: {
                            Label("Слушать", systemImage: "play.fill")
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            player.startWave(seeds: ["artist:\(artistID)"], title: "Волна: \(name)")
                        } label: {
                            Label("Волна", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [Album]?) -> some View {
        if let albums, !albums.isEmpty {
            Section(title) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink {
                                AlbumView(album: album)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    CoverImage(uri: album.coverUri, size: 300, corner: 10).frame(width: 140)
                                    Text(album.title).font(.footnote.weight(.medium)).lineLimit(1)
                                    if let year = album.year {
                                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            info = try await client.artistBrief(id: artistID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddToPlaylistView: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    let track: Track
    @State private var playlists: [Playlist] = []
    @State private var adding: String?
    @State private var error: String?

    var body: some View {
        List(playlists) { playlist in
            Button {
                Task { await add(to: playlist) }
            } label: {
                HStack(spacing: 12) {
                    CoverImage(uri: playlist.coverURI, size: 100).frame(width: 44, height: 44)
                    Text(playlist.title)
                    Spacer()
                    if adding == playlist.id { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(adding != nil)
        }
        .navigationTitle("В плейлист")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let error { ErrorBanner(message: error) { self.error = nil } }
        }
        .task {
            guard let client = session.client, let uid = session.uid else { return }
            playlists = (try? await client.playlists(uid: uid)) ?? []
        }
    }

    private func add(to playlist: Playlist) async {
        guard let client = session.client, let uid = session.uid else { return }
        adding = playlist.id
        defer { adding = nil }
        do {
            try await client.addToPlaylist(track, uid: uid, kind: playlist.kind.value)
            router.destination = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
