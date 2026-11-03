import SwiftUI

struct SearchView: View {
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var suggestions: [String] = []
    @State private var recent: [String] = SearchHistory.load()
    @State private var error: String?

    /// Wait for the user to stop typing before hitting the API.
    private static let debounce: Duration = .milliseconds(350)

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    recentSection
                } else {
                    results
                }
            }
            .terminalPage()
            .overlay {
                if query.isEmpty && recent.isEmpty {
                    ContentUnavailableView("Поиск", systemImage: "magnifyingglass",
                                           description: Text("Треки, артисты, альбомы, плейлисты"))
                } else if !query.isEmpty, let error {
                    ErrorBanner(message: error) { Task { await search(query) } }
                }
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Что послушаем?")
            .searchSuggestions {
                ForEach(suggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "magnifyingglass")
                        .searchCompletion(suggestion)
                }
            }
            .onSubmit(of: .search) { remember(query) }
            .task(id: query) {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                async let lookup: Void = search(query)
                async let hints: Void = suggest(query)
                _ = await (lookup, hints)
                // Picking a suggestion fills the field with it: keep that as a recent search.
                if suggestions.contains(query) { remember(query) }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.self) { item in
                    Button {
                        Haptics.tick()
                        query = item
                    } label: {
                        Label(item, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                    }
                    .terminalRow()
                    .swipeActions {
                        Button("Убрать", systemImage: "xmark", role: .destructive) {
                            recent.removeAll { $0 == item }
                            SearchHistory.save(recent)
                        }
                    }
                }
            } header: {
                HStack {
                    TerminalLabel(text: "недавние")
                    Spacer()
                    Button("очистить") {
                        Haptics.tap()
                        recent = []
                        SearchHistory.save([])
                    }
                    .font(Brand.mono(12, weight: .bold))
                    .foregroundStyle(Brand.acid)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let artists = result?.artists?.results, !artists.isEmpty {
            Section(header: TerminalLabel(text: "артисты")) {
                shelf {
                    ForEach(artists.prefix(12)) { artist in
                        NavigationLink {
                            ArtistView(artistID: artist.id.value, name: artist.name)
                        } label: { ArtistCard(artist: artist) }
                    }
                }
            }
        }

        if let tracks = result?.tracks?.results, !tracks.isEmpty {
            Section(header: TerminalLabel(text: "треки")) {
                TrackList(tracks: tracks)
            }
        }

        if let albums = result?.albums?.results, !albums.isEmpty {
            Section(header: TerminalLabel(text: "альбомы")) {
                shelf {
                    ForEach(albums.prefix(12)) { album in
                        NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                    }
                }
            }
        }

        if let playlists = result?.playlists?.results, !playlists.isEmpty {
            Section(header: TerminalLabel(text: "плейлисты")) {
                ForEach(playlists.prefix(8)) { playlist in
                    NavigationLink(playlist.title) { PlaylistView(playlist: playlist) }
                        .terminalRow()
                }
            }
        }
    }

    private func shelf<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) { content() }
                .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .terminalRow()
    }

    private func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let client = session.client, !text.isEmpty else {
            result = nil
            return
        }
        do {
            result = try await client.search(text)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggest(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let client = session.client, text.count >= 2 else {
            suggestions = []
            return
        }
        suggestions = (try? await client.searchSuggestions(text)) ?? []
    }

    private func remember(_ text: String) {
        recent = SearchHistory.adding(text, to: recent)
        SearchHistory.save(recent)
    }
}

/// Recent queries, newest first, kept on the phone only.
enum SearchHistory {
    private static let key = "searchHistory"
    private static let limit = 12

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ items: [String]) {
        UserDefaults.standard.set(items, forKey: key)
    }

    static func adding(_ text: String, to items: [String]) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return items }
        let rest = items.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        return Array(([clean] + rest).prefix(limit))
    }
}
