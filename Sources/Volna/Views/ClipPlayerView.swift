import AVKit
import Combine
import SwiftUI

extension YMClient.Clip: Identifiable {
    var id: String { clipId.map(String.init) ?? uuid ?? previewUrl ?? "clip" }
}

/// Full-screen player for a Yandex music video. If the stream won't play, offers YouTube instead.
struct ClipPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let clip: YMClient.Clip
    let fallback: URL
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player, !failed {
                VideoPlayer(player: player).ignoresSafeArea()
            } else if failed {
                VStack(spacing: 14) {
                    Text("> клип не открылся").font(Brand.mono(14, weight: .bold)).foregroundStyle(Brand.acid)
                    Button("Найти на YouTube") { openURL(fallback); dismiss() }
                        .buttonStyle(.glassProminent).tint(Brand.acid)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).padding(12)
            }
            .buttonStyle(.glass)
            .padding()
        }
        .task {
            guard let url = clip.streamURL else { failed = true; return }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
            for await status in item.publisher(for: \.status).values where status == .failed {
                failed = true
                break
            }
        }
        .onDisappear { player?.pause() }
        .preferredColorScheme(.dark)
    }
}
