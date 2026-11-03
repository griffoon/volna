import SwiftUI

struct LibraryView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @State private var playlists: [Playlist] = []
    @State private var error: String?
    @State private var creating = false
    @State private var newPlaylistTitle = ""

    var body: some View {
        NavigationStack {
            List {
                TerminalHeader(title: "Коллекция", caption: session.displayName.map { "user: \($0.lowercased())" })
                    .terminalRow()
                    .listRowSeparator(.hidden)

                NavigationLink {
                    LikedTracksView()
                } label: {
                    LikedHero(count: session.likedRefs.count)
                }
                .terminalRow()
                .listRowSeparator(.hidden)

                NavigationLink {
                    HistoryView()
                } label: {
                    Label {
                        Text("История").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Brand.acid)
                    }
                }
                .terminalRow()

                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            HStack(spacing: 14) {
                                CoverImage(uri: playlist.coverURI, size: 120)
                                    .frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.title)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    if let count = playlist.trackCount {
                                        Text("[\(count) трк]")
                                            .font(Brand.mono(11))
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                            }
                        }
                        .terminalRow()
                    }
                } header: {
                    HStack {
                        TerminalLabel(text: "плейлисты · \(playlists.count)")
                        Spacer()
                        Button {
                            Haptics.tap()
                            newPlaylistTitle = ""
                            creating = true
                        } label: {
                            Label("новый", systemImage: "plus")
                                .font(Brand.mono(12, weight: .bold))
                                .foregroundStyle(Brand.acid)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .terminalPage()
            .overlay {
                if let error { ErrorBanner(message: error) { Task { await load() } } }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await load() }
            .refreshable { await load() }
            .alert("Новый плейлист", isPresented: $creating) {
                TextField("Название", text: $newPlaylistTitle)
                Button("Отмена", role: .cancel) {}
                Button("Создать") { Task { await createPlaylist() } }
            }
        }
    }

    private func createPlaylist() async {
        let title = newPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let client = session.client, let uid = session.uid else { return }
        do {
            _ = try await client.createPlaylist(title: title, uid: uid, isPublic: false)
            Haptics.success()
            await load()
        } catch {
            self.error = error.localizedDescription
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

/// "Мне нравится" as a big terminal block: count in display type, acid accent.
private struct LikedHero: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("// мне нравится")
                    .font(Brand.mono(12, weight: .bold))
                    .foregroundStyle(Brand.acid)
                Spacer()
                Image(systemName: "heart.fill").foregroundStyle(Brand.acid)
            }
            Text(count > 0 ? count.formatted(.number.grouping(.never)) : "····")
                .font(Brand.display(64))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("треков в коллекции")
                .font(Brand.mono(12))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.acid.opacity(0.5), lineWidth: 1))
        .padding(.vertical, 6)
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
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    TerminalHeader(title: "Мне нравится",
                                   caption: loading ? "loading \(tracks.count)/\(session.likedRefs.count)…" : "\(tracks.count) трк")
                    TerminalActions {
                        player.play(tracks)
                    } shuffle: {
                        player.play(tracks.shuffled())
                    }
                    .disabled(tracks.isEmpty)
                }
                .padding(.bottom, 8)
            }
            .terminalRow()
            .listRowSeparator(.hidden)

            TrackList(tracks: tracks)
        }
        .terminalPage()
        .overlay {
            if loading && tracks.isEmpty { ProgressView().tint(Brand.acid) }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client, let uid = session.uid else { return }
        loading = true
        defer { loading = false }
        // Show what we already have straight away, then fetch only tracks liked since.
        if tracks.isEmpty { tracks = session.likedTrackCache }
        do {
            let refs = try await client.likedTracks(uid: uid).map(\.ref)
            var known = Dictionary(session.likedTrackCache.map { ($0.id.value, $0) }, uniquingKeysWith: { a, _ in a })
            let missing = refs.filter { known[String($0.split(separator: ":")[0])] == nil }
            for start in stride(from: 0, to: missing.count, by: Self.batchSize) {
                let chunk = Array(missing[start..<min(start + Self.batchSize, missing.count)])
                for track in try await client.tracks(refs: chunk) { known[track.id.value] = track }
                tracks = refs.compactMap { known[String($0.split(separator: ":")[0])] }
            }
            tracks = refs.compactMap { known[String($0.split(separator: ":")[0])] }
            session.likedTrackCache = tracks
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlaylistView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var title: String?
    @State private var isPublic: Bool?
    @State private var revision: Int?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @State private var error: String?

    /// Editing is offered only for the user's own playlists.
    private var isOwn: Bool { playlist.uid.value == session.uid }

    var body: some View {
        List {
            Section {
                CollectionHeader(
                    kind: isOwn ? ((isPublic ?? (playlist.visibility == "public")) ? "playlist · public" : "playlist · private") : "playlist",
                    title: title ?? playlist.title,
                    subtitle: "\(tracks.count) трк",
                    coverURI: playlist.coverURI
                ) {
                    player.play(tracks)
                } shuffle: {
                    player.play(tracks.shuffled())
                }
            }
            .terminalRow()
            .listRowSeparator(.hidden)

            TrackList(tracks: tracks, numbered: true, onRemove: isOwn ? { index in Task { await remove(at: index) } } : nil)
        }
        .terminalPage()
        .overlay {
            if let error { ErrorBanner(message: error) { self.error = nil; Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Переименовать", systemImage: "pencil") {
                            newTitle = title ?? playlist.title
                            renaming = true
                        }
                        let open = isPublic ?? (playlist.visibility == "public")
                        Button(open ? "Сделать приватным" : "Сделать публичным",
                               systemImage: open ? "lock" : "globe") {
                            Task { await setVisibility(!open) }
                        }
                        Button("Удалить плейлист", systemImage: "trash", role: .destructive) {
                            confirmDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Управление плейлистом")
                }
            }
        }
        .alert("Новое название", isPresented: $renaming) {
            TextField("Название", text: $newTitle)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") { Task { await rename() } }
        }
        .confirmationDialog("Удалить «\(title ?? playlist.title)»?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await deletePlaylist() } }
        } message: {
            Text("Плейлист пропадёт и в официальном приложении.")
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let full = try await client.playlist(uid: playlist.uid.value, kind: playlist.kind.value)
            revision = full.revision
            let shorts = full.tracks ?? []
            let embedded = shorts.compactMap(\.track)
            tracks = embedded.count == shorts.count ? embedded : try await client.tracks(refs: shorts.map(\.ref))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(at index: Int) async {
        guard let client = session.client, let uid = session.uid, let revision, tracks.indices.contains(index) else { return }
        let removed = tracks.remove(at: index)
        Haptics.slam()
        do {
            let updated = try await client.removeFromPlaylist(kind: playlist.kind.value, uid: uid, index: index, revision: revision)
            self.revision = updated.revision
        } catch {
            tracks.insert(removed, at: index)
            self.error = error.localizedDescription
        }
    }

    private func rename() async {
        let value = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let client = session.client, let uid = session.uid else { return }
        do {
            title = try await client.renamePlaylist(kind: playlist.kind.value, uid: uid, title: value).title
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setVisibility(_ makePublic: Bool) async {
        guard let client = session.client, let uid = session.uid else { return }
        do {
            let updated = try await client.setPlaylistVisibility(kind: playlist.kind.value, uid: uid, isPublic: makePublic)
            isPublic = (updated.visibility ?? (makePublic ? "public" : "private")) == "public"
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deletePlaylist() async {
        guard let client = session.client, let uid = session.uid else { return }
        do {
            try await client.deletePlaylist(kind: playlist.kind.value, uid: uid)
            Haptics.slam()
            dismiss()
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
    @State private var moreFromArtist: [Album] = []
    @State private var similarArtists: [Artist] = []
    @State private var error: String?

    private var mainArtist: Artist? { album.artists?.first }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    CollectionHeader(
                        kind: "album",
                        title: album.title,
                        subtitle: [album.artists?.map(\.name).joined(separator: ", "), album.year.map(String.init)]
                            .compactMap { $0 }.joined(separator: " · "),
                        coverURI: album.coverUri
                    ) {
                        player.play(tracks)
                    } shuffle: {
                        player.play(tracks.shuffled())
                    }
                    albumActions
                }
            }
            .terminalRow()
            .listRowSeparator(.hidden)

            TrackList(tracks: tracks, numbered: true)

            if !moreFromArtist.isEmpty, let artist = mainArtist {
                Section {
                    shelf {
                        ForEach(moreFromArtist) { other in
                            NavigationLink { AlbumView(album: other) } label: { AlbumCard(album: other) }
                        }
                    }
                } header: {
                    TerminalLabel(text: "ещё у \(artist.name.lowercased())")
                }
            }

            if !similarArtists.isEmpty {
                Section {
                    shelf {
                        ForEach(similarArtists) { artist in
                            NavigationLink {
                                ArtistView(artistID: artist.id.value, name: artist.name)
                            } label: { ArtistCard(artist: artist) }
                        }
                    }
                } header: {
                    TerminalLabel(text: "похожие артисты")
                }
            }
        }
        .terminalPage()
        .overlay {
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var albumActions: some View {
        let liked = session.isLiked(album: album)
        return HStack(spacing: 10) {
            Button {
                liked ? Haptics.tap() : Haptics.success(); Task { await session.toggleLike(album: album) }
            } label: {
                Label(liked ? "в коллекции" : "в коллекцию", systemImage: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? Brand.acid : .white)
            }
            Button {
                Haptics.launch(); player.startWave(seeds: ["album:\(album.id.value)"], title: "Волна: \(album.title)")
            } label: {
                Label("волна по альбому", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .font(Brand.mono(12, weight: .bold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
    }

    private func shelf<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) { content() }
        }
        .scrollIndicators(.hidden)
        .terminalRow()
        .listRowSeparator(.hidden)
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            tracks = try await client.album(id: album.id.value).tracks
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if session.likedAlbums.isEmpty { await session.loadLikedAlbums() }
        if let artist = mainArtist, let brief = try? await client.artistBrief(id: artist.id.value) {
            let others = (brief.albums ?? []) + (brief.alsoAlbums ?? [])
            moreFromArtist = Array(others.filter { $0.id != album.id }.prefix(12))
            similarArtists = Array((brief.similarArtists ?? []).prefix(12))
        }
    }
}

/// Cover on the left, type tag and Dela title on the right, actions below.
struct CollectionHeader: View {
    let kind: String
    let title: String
    let subtitle: String?
    let coverURI: String?
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 14) {
                CoverImage(uri: coverURI, size: 400)
                    .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 6) {
                    Text("> type: \(kind)")
                        .font(Brand.mono(11, weight: .medium))
                        .foregroundStyle(Brand.acid)
                    Text(title)
                        .font(Brand.display(24))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle.lowercased())
                            .font(Brand.mono(12))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                    }
                }
            }
            TerminalActions(play: play, shuffle: shuffle)
        }
        .padding(.vertical, 8)
    }
}
