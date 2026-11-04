import SwiftUI

struct LibraryView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @State private var playlists: [Playlist] = []
    @State private var error: String?
    @State private var creating = false
    @State private var newPlaylistTitle = ""
    /// A few liked tracks for the moving cover wall.
    @State private var wall: [Track] = []
    @State private var startingLiked = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    NavigationLink { LikedTracksView() } label: {
                        LikedWall(count: session.likedRefs.count, tracks: wall,
                                  isStarting: startingLiked,
                                  play: { Task { await playLiked(shuffled: false) } },
                                  shuffle: { Task { await playLiked(shuffled: true) } })
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })

                    if !session.pins.isEmpty || !session.presaves.isEmpty { tokens }

                    crate

                    NavigationLink { HistoryView() } label: {
                        HStack(spacing: 10) {
                            Text("$").foregroundStyle(Brand.acid)
                            Text("history --recent").foregroundStyle(.white)
                            Spacer()
                            Text("история ›").foregroundStyle(.white.opacity(0.5))
                        }
                        .font(Brand.mono(14, weight: .bold))
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .background(Brand.ink)
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("> ~/коллекция" + (session.displayName.map { " · \($0.lowercased())" } ?? ""))
                .font(Brand.mono(11, weight: .medium))
                .foregroundStyle(Brand.acid)
            Text("КОЛЛЕКЦИЯ")
                .font(Brand.display(46))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(stats)
                .font(Brand.mono(12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var stats: String {
        var parts = ["\(session.likedRefs.count) трк"]
        if !playlists.isEmpty { parts.append("\(playlists.count) плейл.") }
        if !session.pins.isEmpty { parts.append("\(session.pins.count) закрепл.") }
        return parts.joined(separator: " · ")
    }

    // MARK: Pins and presaves as round tokens

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 10) {
            TerminalLabel(text: "под рукой").padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(session.presaves) { album in
                        NavigationLink { AlbumView(album: album) } label: {
                            Token(cover: album.coverUri, title: album.title,
                                  badge: album.releaseDay.map { $0.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))) },
                                  round: false)
                        }
                    }
                    ForEach(session.pins) { PinnedLink(pin: $0) }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .buttonStyle(.plain)
        }
    }

    // MARK: Playlists as a crate you flip through

    private var crate: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TerminalLabel(text: "плейлисты · \(playlists.count)")
                Spacer()
                Text("листай →")
                    .font(Brand.mono(11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(playlists) { playlist in
                        NavigationLink { PlaylistView(playlist: playlist) } label: {
                            CrateCard(cover: playlist.coverURI, title: playlist.title,
                                      caption: playlist.trackCount.map { "[\($0) трк]" })
                        }
                        .buttonStyle(.plain)
                        .crateFlip()
                    }
                    Button {
                        Haptics.tap()
                        newPlaylistTitle = ""
                        creating = true
                    } label: {
                        CrateCard(cover: nil, title: "новый плейлист", caption: "+ создать", isNew: true)
                    }
                    .buttonStyle(.plain)
                    .crateFlip()
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, 60, for: .scrollContent)
            .scrollIndicators(.hidden)
            .frame(height: 270)
            .onScrollTargetVisibilityChange(idType: Playlist.ID.self, threshold: 0.9) { _ in Haptics.tick() }
        }
    }

    // MARK: Actions

    private func playLiked(shuffled: Bool) async {
        guard !startingLiked else { return }
        startingLiked = true
        defer { startingLiked = false }
        var tracks = session.likedTrackCache
        if tracks.isEmpty, let client = session.client {
            tracks = (try? await client.tracks(refs: Array(session.likedRefs.prefix(300)))) ?? []
        }
        guard !tracks.isEmpty else { return }
        Haptics.thump()
        player.play(shuffled ? tracks.shuffled() : tracks)
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
            async let pins: Void = session.loadPins()
            async let presaves: Void = session.loadPresaves()
            playlists = try await client.playlists(uid: uid)
            await pins
            await presaves
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if wall.isEmpty {
            let cached = Array(session.likedTrackCache.prefix(24))
            wall = cached.isEmpty ? ((try? await client.tracks(refs: Array(session.likedRefs.prefix(24)))) ?? []) : cached
        }
    }
}

/// "Мне нравится": two rows of liked covers drifting past each other in grey, a huge count on
/// top, play and shuffle at hand. Tapping the block opens the full list.
private struct LikedWall: View {
    let count: Int
    let tracks: [Track]
    let isStarting: Bool
    let play: () -> Void
    let shuffle: () -> Void

    private static let tile: CGFloat = 66

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 6) {
                drifting(Array(tracks.prefix(12)), speed: 14)
                drifting(Array(tracks.dropFirst(12).prefix(12)), speed: -10)
                drifting(Array(tracks.prefix(12).reversed()), speed: 8)
            }
            .grayscale(1)
            .opacity(0.55)
            .frame(height: Self.tile * 3 + 12)
            .clipped()
            .overlay(LinearGradient(colors: [Brand.ink.opacity(0.1), Brand.ink.opacity(0.95)],
                                    startPoint: .top, endPoint: .bottom))

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("// мне нравится")
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(Brand.acid)
                    Text(count > 0 ? count.formatted(.number.grouping(.never)) : "····")
                        .font(Brand.display(60))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("треков")
                        .font(Brand.mono(12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                HStack(spacing: 10) {
                    Button(action: shuffle) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .background(.black.opacity(0.5), in: .circle)
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .accessibilityLabel("Перемешать «Мне нравится»")
                    Button(action: play) {
                        Group {
                            if isStarting {
                                ProgressView().tint(Brand.ink)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 22, weight: .heavy))
                            }
                        }
                        .foregroundStyle(Brand.ink)
                        .frame(width: 60, height: 60)
                        .background(Brand.acid, in: .circle)
                        .shadow(color: Brand.acid.opacity(0.5), radius: 14)
                    }
                    .accessibilityLabel("Играть «Мне нравится»")
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.acid.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 20)
    }

    /// One endless row of covers sliding sideways at `speed` points per second.
    private func drifting(_ row: [Track], speed: Double) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let width = CGFloat(max(row.count, 1)) * (Self.tile + 6)
            let shift = CGFloat((context.date.timeIntervalSinceReferenceDate * speed).truncatingRemainder(dividingBy: Double(width)))
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    ForEach(Array(row.enumerated()), id: \.offset) { _, track in
                        CoverImage(uri: track.cover, size: 150, corner: 2)
                            .frame(width: Self.tile, height: Self.tile)
                    }
                }
            }
            .offset(x: speed > 0 ? -shift : shift - width)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.tile)
        .accessibilityHidden(true)
    }
}

/// A playlist as a record in a crate: a big cover with its title under it.
private struct CrateCard: View {
    let cover: String?
    let title: String
    let caption: String?
    var isNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isNew {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.03))
                        Image(systemName: "plus").font(.system(size: 40, weight: .light)).foregroundStyle(Brand.acid)
                    }
                    .overlay(Rectangle().stroke(Brand.acid.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                } else {
                    CoverImage(uri: cover, size: 600, corner: 3)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.12), lineWidth: 1))
                }
            }
            .frame(width: 200, height: 200)
            .shadow(color: .black.opacity(0.7), radius: 18, y: 10)
            Text(title)
                .font(Brand.display(16))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(Brand.mono(11, weight: .bold))
                    .foregroundStyle(isNew ? Brand.acid : .white.opacity(0.45))
            }
        }
        .frame(width: 200, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

/// Small round (artist) or square (release) token with a caption, for pins and presaves.
private struct Token: View {
    let cover: String?
    let title: String
    let badge: String?
    let round: Bool

    var body: some View {
        VStack(spacing: 6) {
            CoverImage(uri: cover, size: 200, corner: round ? 40 : 3)
                .frame(width: 80, height: 80)
                .overlay(alignment: .bottom) {
                    if let badge {
                        Text(badge)
                            .font(Brand.mono(10, weight: .heavy))
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Brand.acid, in: .capsule)
                            .offset(y: 8)
                    }
                }
            Text(title)
                .font(Brand.mono(11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 88)
                .padding(.top, badge == nil ? 0 : 6)
        }
    }
}

private extension View {
    /// Records leaning back as they move away from the middle of the crate.
    func crateFlip() -> some View {
        scrollTransition(.interactive, axis: .horizontal) { content, phase in
            content
                .rotation3DEffect(.degrees(phase.value * -38), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .scaleEffect(1 - abs(phase.value) * 0.14)
                .opacity(1 - abs(phase.value) * 0.45)
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
            ToolbarItem(placement: .topBarTrailing) {
                PinToggle(target: .playlist(uid: playlist.uid.value, kind: playlist.kind.value))
            }
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
    @State private var releaseDate: String?

    /// The album with whatever release date the detail request returned.
    private var dated: Album {
        var copy = album
        copy.releaseDate = releaseDate ?? album.releaseDate
        return copy
    }
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
                    artistLinks
                    upcomingBanner
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

    /// The album's artists as chips that open their pages.
    @ViewBuilder
    private var artistLinks: some View {
        if let artists = album.artists, !artists.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(artists) { artist in
                        NavigationLink {
                            ArtistView(artistID: artist.id.value, name: artist.name)
                        } label: {
                            HStack(spacing: 8) {
                                CoverImage(uri: artist.cover?.uri, size: 100, corner: 14)
                                    .frame(width: 28, height: 28)
                                    .clipShape(.circle)
                                Text(artist.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Brand.acid)
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 12)
                            .frame(height: 36)
                            .background(.white.opacity(0.06), in: .capsule)
                            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// For releases that aren't out yet: the date and a presave toggle.
    @ViewBuilder
    private var upcomingBanner: some View {
        if dated.isUpcoming, let day = dated.releaseDay {
            let saved = session.isPresaved(dated)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("> скоро").font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.acid)
                    Text("выйдет \(day.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "ru_RU"))))")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                Spacer()
                Button {
                    Haptics.success()
                    Task { await session.togglePresave(dated) }
                } label: {
                    Label(saved ? "пресейв ✓" : "пресейв", systemImage: saved ? "bell.fill" : "bell")
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(saved ? Brand.ink : Brand.acid)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(saved ? Brand.acid : .clear, in: .capsule)
                        .overlay(Capsule().stroke(Brand.acid, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.acid.opacity(0.4), lineWidth: 1))
        }
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
            Spacer(minLength: 0)
            PinToggle(target: .album(album.id.value))
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
            let full = try await client.album(id: album.id.value)
            tracks = full.tracks
            releaseDate = full.releaseDate ?? album.releaseDate
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
