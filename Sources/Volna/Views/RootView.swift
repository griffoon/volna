import SwiftUI

/// Shows the mini player only once something has been played. Hiding the accessory needs
/// iOS 26.1; on 26.0 it stays visible as before.
private struct MiniPlayerAccessory<Accessory: View>: ViewModifier {
    let visible: Bool
    @ViewBuilder let accessory: () -> Accessory

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: visible, content: accessory)
        } else {
            content.tabViewBottomAccessory(content: accessory)
        }
    }
}

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
        .modifier(MiniPlayerAccessory(visible: player.current != nil) {
            MiniPlayer { showPlayer = true }
                .matchedTransitionSource(id: "player", in: playerZoom)
        })
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
        .onChange(of: player.errorMessage) { _, message in
            if message != nil { Haptics.error() }
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
