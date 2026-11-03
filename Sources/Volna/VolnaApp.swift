import SwiftUI

@main
struct VolnaApp: App {
    @State private var session = Session()
    @State private var player = PlayerEngine()
    @State private var router = Router()

    init() {
        Brand.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isLoggedIn {
                    RootView()
                } else {
                    LoginView()
                }
            }
            .environment(session)
            .environment(player)
            .environment(router)
            .tint(Brand.acid)
            .preferredColorScheme(.dark)
            .task(id: session.isLoggedIn) {
                player.attach(session.client)
                session.onLike = { [player] track, liked in player.noteLike(track, liked: liked) }
                session.onDislike = { [player] track in player.noteDislike(track) }
                await session.refreshAccount()
                player.uid = session.uid
            }
            .onOpenURL(perform: handle)
        }
    }

    /// `volna://wave`, `volna://liked`, `volna://toggle` — used by the widget and Control Center button.
    private func handle(_ url: URL) {
        guard url.scheme == "volna", session.isLoggedIn else { return }
        switch url.host() {
        case "wave":
            if player.isWave, player.current != nil {
                if !player.isPlaying { player.togglePlay() }
            } else {
                player.startWave()
            }
        case "toggle":
            if player.current == nil { player.startWave() } else { player.togglePlay() }
        case "liked":
            Task { await playLikedShuffled() }
        default:
            break
        }
    }

    private func playLikedShuffled() async {
        if session.uid == nil { await session.refreshAccount() }
        guard let client = session.client, let uid = session.uid,
              let likes = try? await client.likedTracks(uid: uid),
              let tracks = try? await client.tracks(refs: Array(likes.map(\.ref).shuffled().prefix(100)))
        else { return }
        player.play(tracks)
    }
}
