import SwiftUI

struct AddToPlaylistView: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    let track: Track
    @State private var playlists: [Playlist] = []
    @State private var adding: String?
    @State private var error: String?

    var body: some View {
        List(playlists) { playlist in
            Button {
                Task { await add(to: playlist) }
            } label: {
                HStack(spacing: 12) {
                    CoverImage(uri: playlist.coverURI, size: 100).frame(width: 44, height: 44)
                    Text(playlist.title)
                    Spacer()
                    if adding == playlist.id { ProgressView() }
                }
            }
            .buttonStyle(.plain)
            .disabled(adding != nil)
        }
        .navigationTitle("В плейлист")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let error { ErrorBanner(message: error) { self.error = nil } }
        }
        .task {
            guard let client = session.client, let uid = session.uid else { return }
            playlists = (try? await client.playlists(uid: uid)) ?? []
        }
    }

    private func add(to playlist: Playlist) async {
        guard let client = session.client, let uid = session.uid else { return }
        adding = playlist.id
        defer { adding = nil }
        do {
            try await client.addToPlaylist(track, uid: uid, kind: playlist.kind.value)
            Haptics.success(); router.destination = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
