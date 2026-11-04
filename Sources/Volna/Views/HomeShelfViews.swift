import SwiftUI

/// Full-screen versions of the home shelves, opened by tapping a shelf's title.

/// Cards in a grid under a big title.
struct ShelfGridView<Item: Identifiable, Card: View>: View {
    let title: String
    var caption: String?
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card
    /// Called when the last row shows up, to load more.
    var onReachEnd: (() async -> Void)?
    var isLoadingMore = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TerminalHeader(title: title, caption: caption)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        card(item)
                            .task {
                                if item.id == items.last?.id { await onReachEnd?() }
                            }
                    }
                }
                if isLoadingMore {
                    Text("> догружаю…")
                        .font(Brand.mono(12))
                        .foregroundStyle(Brand.acid)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .buttonStyle(.plain)
        .background(Brand.ink)
    }
}

/// A plain track list under a big title (chart, track events).
struct ShelfTracksView: View {
    let title: String
    var caption: String?
    let tracks: [Track]
    var numbered = false

    var body: some View {
        List {
            TerminalHeader(title: title, caption: caption)
                .terminalRow()
                .listRowSeparator(.hidden)
            TrackList(tracks: tracks, numbered: numbered)
        }
        .terminalPage()
    }
}

/// Every new release, loaded page by page as you scroll. What was loaded stays in memory,
/// so leaving and coming back keeps the list where it was.
@MainActor
@Observable
final class ReleasesFeed {
    static let shared = ReleasesFeed()

    private(set) var albums: [Album] = []
    private(set) var isLoading = false
    private var ids: [String] = []
    private static let page = 24

    var hasMore: Bool { ids.isEmpty || albums.count < ids.count }

    /// Seeds the feed with what the home shelf already has.
    func prime(ids: [String], albums first: [Album]) {
        guard self.ids != ids else { return }
        self.ids = ids
        albums = first
    }

    func loadMore(client: YMClient?) async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if ids.isEmpty { ids = (try? await client.newReleaseIDs()) ?? [] }
        let next = Array(ids.dropFirst(albums.count).prefix(Self.page))
        guard !next.isEmpty else { return }
        let loaded = (try? await client.albums(ids: next)) ?? []
        let known = Set(albums.map(\.id))
        albums += loaded.filter { !known.contains($0.id) }
    }
}

struct ReleasesFullView: View {
    @Environment(Session.self) private var session
    private var feed: ReleasesFeed { .shared }

    var body: some View {
        ShelfGridView(title: "Новые релизы", caption: "landing3/new-releases", items: feed.albums,
                      card: { album in
                          NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                      },
                      onReachEnd: { if feed.hasMore { await feed.loadMore(client: session.client) } },
                      isLoadingMore: feed.isLoading)
            .task { if feed.albums.isEmpty { await feed.loadMore(client: session.client) } }
    }
}
