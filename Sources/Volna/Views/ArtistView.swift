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
        }
        .terminalPage()
        .overlay {
            if info == nil, error == nil { ProgressView().tint(Brand.acid) }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { PinToggle(target: .artist(artistID)) }
        }
        .task { await load() }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(uri: info?.artist.coverURI, size: 800, corner: 0)
                .grayscale(0.4)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipped()
                .overlay(LinearGradient(colors: [.clear, Brand.ink], startPoint: .center, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 12) {
                if let listeners = about?.monthlyListeners {
                    Text("> \(listeners.formatted(.number.notation(.compactName).locale(Locale(identifier: "ru_RU")))) слушателей за месяц")
                        .font(Brand.mono(12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(info?.artist.name ?? name)
                    .font(Brand.display(38))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 10) {
                    Button {
                        Haptics.thump()
                        player.play(info?.popularTracks ?? [])
                    } label: {
                        Label("СЛУШАТЬ", systemImage: "play.fill")
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
        about = await aboutTask
        discography = await albumsTask ?? []
        concerts = await concertsTask ?? []
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
