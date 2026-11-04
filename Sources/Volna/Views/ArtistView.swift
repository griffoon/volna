import SwiftUI

struct ArtistView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    let artistID: String
    let name: String
    @State private var info: ArtistBriefInfo?
    @State private var about: ArtistAbout?
    @State private var discography: [Album] = []
    @State private var concerts: [Concert] = []
    @State private var bioExpanded = false
    @State private var error: String?
    @State private var photoPage = 0
    @State private var showPhotos = false
    @State private var genius: URL?
    @State private var loadingAll = false

    /// All of the artist's tracks in random order (not just the popular ten, not in order).
    private func playShuffled() async {
        guard !loadingAll else { return }
        loadingAll = true
        defer { loadingAll = false }
        var tracks = (try? await session.client?.artistTracks(id: artistID, pageSize: 300)) ?? []
        if tracks.isEmpty { tracks = info?.popularTracks ?? [] }
        guard !tracks.isEmpty else { return }
        player.play(tracks.shuffled())
    }

    /// Bio lines shown before «читать дальше».
    private static let bioPreviewLines = 4

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let tracks = info?.popularTracks, !tracks.isEmpty {
                Section(header: TerminalLabel(text: "популярное")) {
                    TrackList(tracks: Array(tracks.prefix(10)), numbered: true)
                }
            }

            albumShelf("дискография · \(discography.count)", discography.isEmpty ? info?.albums : discography)
            albumShelf("сборники и участие", info?.alsoAlbums)

            if !concerts.isEmpty {
                Section(header: TerminalLabel(text: "концерты · \(concerts.count)")) {
                    ForEach(concerts) { concert in
                        ConcertRow(concert: concert).terminalRow()
                    }
                }
            }

            if let text = about?.description, !text.isEmpty {
                Section(header: TerminalLabel(text: "об артисте")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(bioExpanded ? nil : Self.bioPreviewLines)
                        Button(bioExpanded ? "свернуть" : "читать дальше") {
                            Haptics.tick()
                            withAnimation(.snappy) { bioExpanded.toggle() }
                        }
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(Brand.acid)
                        .buttonStyle(.plain)
                    }
                    .terminalRow()
                }
            }

            if let similar = info?.similarArtists, !similar.isEmpty {
                Section(header: TerminalLabel(text: "похожие")) {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(similar.prefix(15)) { artist in
                                NavigationLink {
                                    ArtistView(artistID: artist.id.value, name: artist.name)
                                } label: { ArtistCard(artist: artist) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .buttonStyle(.plain)
                    .terminalRow()
                }
            }

            if !profiles.isEmpty {
                Section(header: TerminalLabel(text: "профили")) {
                    ForEach(profiles, id: \.url) { profile in
                        Link(destination: profile.url) {
                            HStack(spacing: 14) {
                                Image(systemName: profile.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Brand.acid)
                                    .frame(width: 26)
                                Text(profile.title)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.vertical, 6)
                        }
                        .terminalRow()
                    }
                }
            }
        }
        .terminalPage()
        .overlay {
            if info == nil, error == nil { ProgressView().tint(Brand.acid) }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .fullScreenCover(isPresented: $showPhotos) {
            ArtistPhotoViewer(photos: info?.photos ?? [], page: $photoPage)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { PinToggle(target: .artist(artistID)) }
        }
        .task { await load() }
    }

    private static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).locale(Locale(identifier: "ru_RU")))
    }

    private var listeners: Int? { about?.monthlyListeners ?? info?.stats?.lastMonthListeners }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            ArtistPhotoPager(photos: info?.photos ?? [], page: $photoPage) { showPhotos = true }
                .frame(height: 380)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let listeners {
                        Label("\(Self.compact(listeners)) слушателей за месяц", systemImage: "headphones")
                    }
                    if let likes = info?.artist.likesCount, likes > 0 {
                        Label(Self.compact(likes), systemImage: "heart.fill")
                    }
                }
                .font(Brand.mono(12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .labelStyle(.titleAndIcon)
                HStack(alignment: .bottom) {
                    Text(info?.artist.name ?? name)
                        .font(Brand.display(38))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 8)
                    let liked = session.isLiked(artistID: artistID)
                    Button {
                        liked ? Haptics.tap() : Haptics.success()
                        Task { await session.toggleLike(artistID: artistID) }
                    } label: {
                        Label(liked ? "ВЫ ПОДПИСАНЫ" : "ПОДПИСАТЬСЯ", systemImage: liked ? "heart.fill" : "heart")
                            .font(Brand.mono(11, weight: .bold))
                            .foregroundStyle(liked ? Brand.acid : .white)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(.black.opacity(0.5), in: .capsule)
                            .overlay(Capsule().stroke(liked ? Brand.acid : .white.opacity(0.4), lineWidth: 1))
                            .symbolEffect(.bounce, value: liked)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    Button {
                        Haptics.thump()
                        Task { await playShuffled() }
                    } label: {
                        Label(loadingAll ? "ЗАГРУЖАЮ…" : "ИГРАТЬ", systemImage: "shuffle")
                            .font(Brand.mono(13, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .foregroundStyle(Brand.ink)
                            .background(Brand.acid, in: .capsule)
                    }
                    Button {
                        Haptics.launch()
                        player.startWave(seeds: ["artist:\(artistID)"], title: "Волна: \(name)")
                    } label: {
                        Label("ВОЛНА", systemImage: "dot.radiowaves.left.and.right")
                            .font(Brand.mono(13, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .foregroundStyle(.white)
                            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [Album]?) -> some View {
        if let albums, !albums.isEmpty {
            Section(header: TerminalLabel(text: title)) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .buttonStyle(.plain)
                .terminalRow()
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
        async let aboutTask = try? client.artistAbout(id: artistID)
        async let albumsTask = try? client.artistDiscography(id: artistID)
        async let concertsTask = try? client.artistConcerts(id: artistID)
        async let geniusTask = Genius.artistPage(name: info?.artist.name ?? name)
        if session.likedArtists.isEmpty { await session.loadLikedArtists() }
        about = await aboutTask
        discography = await albumsTask ?? []
        concerts = await concertsTask ?? []
        genius = await geniusTask
    }

    private struct Profile {
        let title: String
        let symbol: String
        let url: URL
    }

    /// Links Yandex lists for the artist (YouTube, VK, site…) plus Genius when there's an exact match.
    private var profiles: [Profile] {
        var result: [Profile] = []
        for link in info?.artist.links ?? [] {
            guard let url = link.url else { continue }
            let network = (link.socialNetwork ?? link.type ?? "").lowercased()
            let host = url.host()?.lowercased() ?? ""
            let (title, symbol): (String, String) = switch true {
            case network.contains("youtube") || host.contains("youtu"): ("YouTube", "play.rectangle.fill")
            case network.contains("vk") || host.contains("vk.com"): ("ВКонтакте", "person.2.fill")
            case network.contains("telegram") || host.contains("t.me"): ("Telegram", "paperplane.fill")
            case network.contains("instagram") || host.contains("instagram"): ("Instagram", "camera.fill")
            case network.contains("twitter") || host.contains("twitter") || host.contains("x.com"): ("X", "bubble.left.fill")
            case network.contains("tiktok") || host.contains("tiktok"): ("TikTok", "music.note")
            default: (link.title ?? host, "globe")
            }
            result.append(Profile(title: title, symbol: symbol, url: url))
        }
        if let genius, !result.contains(where: { $0.url.host()?.contains("genius") == true }) {
            result.append(Profile(title: "Genius", symbol: "text.quote", url: genius))
        }
        return result
    }
}

private struct ConcertRow: View {
    let concert: Concert

    private static let ru = Locale(identifier: "ru_RU")

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(concert.date.map { $0.formatted(.dateTime.day()) } ?? "--")
                    .font(Brand.display(22))
                    .foregroundStyle(.white)
                Text(concert.date.map { $0.formatted(.dateTime.month(.abbreviated).locale(Self.ru)) } ?? "")
                    .font(Brand.mono(11, weight: .bold))
                    .foregroundStyle(Brand.acid)
            }
            .frame(width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(concert.city ?? concert.concertTitle ?? "Концерт")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text([concert.place, concert.date.map { $0.formatted(date: .omitted, time: .shortened) }]
                        .compactMap { $0 }.joined(separator: " · ").lowercased())
                    .font(Brand.mono(12))
                    .foregroundStyle(.white.opacity(0.55))
                if let link = concert.afishaUrl.flatMap(URL.init(string:)) {
                    Link("билеты на афише ›", destination: link)
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(Brand.acid)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
