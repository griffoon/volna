import Foundation
import Observation

/// Logged-in state shared across the app.
@MainActor
@Observable
final class Session {
    private(set) var client: YMClient?
    private(set) var uid: String?
    private(set) var displayName: String?
    private(set) var hasPlus = false
    private(set) var likedRefs: Set<String> = []
    var lastError: String?

    var isLoggedIn: Bool { client != nil }

    /// Lets the player tell My Wave about likes and dislikes.
    var onLike: ((Track, Bool) -> Void)?
    var onDislike: ((Track) -> Void)?

    init() {
        if let token = TokenStore.load() {
            client = YMClient(token: token)
        }
    }

    func login(token: String) async {
        TokenStore.save(token)
        client = YMClient(token: token)
        await refreshAccount()
    }

    func logout() {
        TokenStore.clear()
        client = nil
        uid = nil
        displayName = nil
        likedRefs = []
    }

    func refreshAccount() async {
        guard let client else { return }
        do {
            let status = try await client.accountStatus()
            uid = status.account.uid?.value
            displayName = status.account.displayName ?? status.account.login
            hasPlus = status.plus?.hasPlus ?? false
            if let uid {
                let likes = try await client.likedTracks(uid: uid)
                likedRefs = Set(likes.map(\.id.value))
            }
        } catch YMError.unauthorized {
            logout()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private(set) var likedAlbums: Set<String> = []

    func loadLikedAlbums() async {
        guard let client, let uid else { return }
        if let ids = try? await client.likedAlbumIDs(uid: uid) { likedAlbums = Set(ids) }
    }

    func isLiked(album: Album) -> Bool { likedAlbums.contains(album.id.value) }

    func toggleLike(album: Album) async {
        guard let client, let uid else { return }
        let id = album.id.value
        let liked = !likedAlbums.contains(id)
        if liked { likedAlbums.insert(id) } else { likedAlbums.remove(id) }
        do {
            try await client.setAlbumLike(liked, albumID: id, uid: uid)
        } catch {
            if liked { likedAlbums.remove(id) } else { likedAlbums.insert(id) }
            lastError = error.localizedDescription
        }
    }

    /// "Не рекомендовать": hides the track from recommendations and skips it.
    func dislike(_ track: Track) async {
        guard let client, let uid else { return }
        if isLiked(track) { await toggleLike(track) }
        let ref = track.albumID.map { "\(track.id.value):\($0.value)" } ?? track.id.value
        do {
            try await client.setDislike(true, trackRef: ref, uid: uid)
            onDislike?(track)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func isLiked(_ track: Track) -> Bool {
        likedRefs.contains(track.id.value)
    }

    func toggleLike(_ track: Track) async {
        guard let client, let uid else { return }
        let liked = !isLiked(track)
        if liked { likedRefs.insert(track.id.value) } else { likedRefs.remove(track.id.value) }
        let ref = track.albumID.map { "\(track.id.value):\($0.value)" } ?? track.id.value
        do {
            try await client.setLike(liked, trackRef: ref, uid: uid)
            onLike?(track, liked)
        } catch {
            if liked { likedRefs.remove(track.id.value) } else { likedRefs.insert(track.id.value) }
            lastError = error.localizedDescription
        }
    }
}
