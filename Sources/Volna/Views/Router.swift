import SwiftUI

/// App-wide sheet destinations reachable from context menus anywhere.
@MainActor
@Observable
final class Router {
    enum Destination: Identifiable {
        case artist(id: String, name: String)
        case album(Album)
        case addToPlaylist(Track)
        case settings
        case waveSettings

        var id: String {
            switch self {
            case .artist(let id, _): "artist-\(id)"
            case .album(let album): "album-\(album.id.value)"
            case .addToPlaylist(let track): "add-\(track.id.value)"
            case .settings: "settings"
            case .waveSettings: "wave-settings"
            }
        }
    }

    var destination: Destination?
}

struct DestinationView: View {
    @Environment(Router.self) private var router
    let destination: Router.Destination

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть", systemImage: "xmark") { router.destination = nil }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .artist(let id, let name): ArtistView(artistID: id, name: name)
        case .album(let album): AlbumView(album: album)
        case .addToPlaylist(let track): AddToPlaylistView(track: track)
        case .settings: SettingsView()
        case .waveSettings: WaveSettingsView()
        }
    }
}

/// Long-press actions shared by every track row and the full player.
struct TrackMenu: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    let track: Track

    var body: some View {
        Section {
            Button("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.playNext(track)
            }
            Button("В конец очереди", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.enqueue(track)
            }
        }
        Section {
            Button("Волна по треку", systemImage: "dot.radiowaves.left.and.right") {
                player.startWave(seeds: ["track:\(track.id.value)"], title: "Волна по треку")
            }
            Button(session.isLiked(track) ? "Убрать из любимых" : "Нравится",
                   systemImage: session.isLiked(track) ? "heart.slash" : "heart") {
                Task { await session.toggleLike(track) }
            }
            Button("Добавить в плейлист", systemImage: "text.badge.plus") {
                router.destination = .addToPlaylist(track)
            }
            Button("Не рекомендовать", systemImage: "hand.thumbsdown", role: .destructive) {
                Task { await session.dislike(track) }
            }
        }
        Section {
            ForEach(track.artists) { artist in
                Button(artist.name, systemImage: "music.microphone") {
                    router.destination = .artist(id: artist.id.value, name: artist.name)
                }
            }
            if let album = track.albums?.first {
                Button(album.title, systemImage: "square.stack") {
                    router.destination = .album(album)
                }
            }
        }
    }
}
