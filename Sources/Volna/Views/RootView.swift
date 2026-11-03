import SwiftUI

struct RootView: View {
    enum TabID: Hashable {
        case wave, library, search
    }

    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @State private var tab: TabID = .wave
    @State private var showPlayer = false
    @Namespace private var playerZoom

    var body: some View {
        TabView(selection: $tab) {
            Tab("Волна", systemImage: "waveform", value: .wave) {
                WaveView()
            }
            Tab("Коллекция", systemImage: "music.note.square.stack", value: .library) {
                LibraryView()
            }
            Tab(value: .search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { showPlayer = true }
                .matchedTransitionSource(id: "player", in: playerZoom)
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "player", in: playerZoom))
        }
        .sheet(item: Binding(get: { showPlayer ? nil : router.destination },
                             set: { router.destination = $0 })) { destination in
            DestinationView(destination: destination)
        }
        .onChange(of: router.destination?.id) { _, id in
            if id != nil { showPlayer = false }
        }
        .task(id: player.current?.cover) {
            await Theme.shared.update(coverURI: player.current?.cover)
        }
        .alert("Ошибка", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }
}
