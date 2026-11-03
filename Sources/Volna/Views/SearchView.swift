import SwiftUI

struct SearchView: View {
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var error: String?

    /// Wait for the user to stop typing before hitting the API.
    private static let debounce: Duration = .milliseconds(350)

    var body: some View {
        NavigationStack {
            List {
                if let albums = result?.albums?.results, !albums.isEmpty {
                    Section("Альбомы") {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 14) {
                                ForEach(albums.prefix(12)) { album in
                                    NavigationLink {
                                        AlbumView(album: album)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            CoverImage(uri: album.coverUri, size: 300, corner: 10)
                                                .frame(width: 130)
                                            Text(album.title).font(.footnote.weight(.medium)).lineLimit(1)
                                            Text(album.artists?.first?.name ?? "")
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 130)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                if let tracks = result?.tracks?.results, !tracks.isEmpty {
                    Section("Треки") {
                        TrackList(tracks: tracks)
                    }
                }

                if let playlists = result?.playlists?.results, !playlists.isEmpty {
                    Section("Плейлисты") {
                        ForEach(playlists.prefix(8)) { playlist in
                            NavigationLink(playlist.title) { PlaylistView(playlist: playlist) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Поиск", systemImage: "magnifyingglass",
                                           description: Text("Треки, альбомы, плейлисты"))
                } else if let error {
                    ErrorBanner(message: error) { Task { await search(query) } }
                }
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Что послушаем?")
            .task(id: query) {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                await search(query)
            }
        }
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
}
