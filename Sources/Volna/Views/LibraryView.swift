import SwiftUI

struct LibraryView: View {
    @Environment(Session.self) private var session
    @State private var playlists: [Playlist] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LikedTracksView()
                    } label: {
                        Label {
                            Text("Мне нравится").font(.headline)
                        } icon: {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.pink.gradient, in: .rect(cornerRadius: 8))
                        }
                    }
                }

                Section("Плейлисты") {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(uri: playlist.coverURI, size: 100)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading) {
                                    Text(playlist.title)
                                    if let count = playlist.trackCount {
                                        Text("\(count) треков").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if let error { ErrorBanner(message: error) { Task { await load() } } }
            }
            .navigationTitle("Коллекция")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard let client = session.client, let uid = session.uid else { return }
        do {
            playlists = try await client.playlists(uid: uid)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LikedTracksView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var error: String?

    /// `POST /tracks` accepts a limited batch per call.
    private static let batchSize = 200

    var body: some View {
        List {
            TrackList(tracks: tracks)
        }
        .listStyle(.plain)
        .overlay {
            if loading && tracks.isEmpty { ProgressView() }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationTitle("Мне нравится")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Перемешать", systemImage: "shuffle") {
                    player.play(tracks.shuffled())
                }
                .disabled(tracks.isEmpty)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client, let uid = session.uid else { return }
        loading = true
        defer { loading = false }
        do {
            let refs = try await client.likedTracks(uid: uid).map(\.ref)
            var loaded: [Track] = []
            for start in stride(from: 0, to: refs.count, by: Self.batchSize) {
                let chunk = Array(refs[start..<min(start + Self.batchSize, refs.count)])
                loaded += try await client.tracks(refs: chunk)
                tracks = loaded
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlaylistView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                CollectionHeader(
                    title: playlist.title,
                    subtitle: playlist.trackCount.map { "\($0) треков" },
                    coverURI: playlist.coverURI
                ) {
                    player.play(tracks)
                } shuffle: {
                    player.play(tracks.shuffled())
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            TrackList(tracks: tracks)
        }
        .listStyle(.plain)
        .overlay {
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let full = try await client.playlist(uid: playlist.uid.value, kind: playlist.kind.value)
            let shorts = full.tracks ?? []
            let embedded = shorts.compactMap(\.track)
            tracks = embedded.count == shorts.count ? embedded : try await client.tracks(refs: shorts.map(\.ref))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AlbumView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    let album: Album
    @State private var tracks: [Track] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                CollectionHeader(
                    title: album.title,
                    subtitle: [album.artists?.map(\.name).joined(separator: ", "), album.year.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "),
                    coverURI: album.coverUri
                ) {
                    player.play(tracks)
                } shuffle: {
                    player.play(tracks.shuffled())
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            TrackList(tracks: tracks)
        }
        .listStyle(.plain)
        .overlay {
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            tracks = try await client.album(id: album.id.value).tracks
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CollectionHeader: View {
    let title: String
    let subtitle: String?
    let coverURI: String?
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            CoverImage(uri: coverURI, size: 600, corner: 14)
                .frame(width: 230)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: play) {
                        Label("Слушать", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    Button(action: shuffle) {
                        Label("Вперемешку", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
