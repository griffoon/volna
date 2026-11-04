import AVKit
import Combine
import SwiftUI

extension YMClient.Clip: Identifiable {
    var id: String { clipId.map(String.init) ?? uuid ?? previewUrl ?? "clip" }
}

/// A button that opens the track's clip, whatever ClipFinder found: Yandex clips play here,
/// YouTube videos and searches open in YouTube. The label is drawn by the caller.
struct ClipLauncher<Label: View>: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @Environment(\.openURL) private var openURL
    let track: Track
    @ViewBuilder let label: (ClipFinder.Result?) -> Label
    @State private var playing: YMClient.Clip?

    private var result: ClipFinder.Result? { ClipFinder.shared.result(for: track) }

    var body: some View {
        Button {
            Haptics.launch()
            switch result {
            case .yandex(let clip):
                if player.isPlaying { player.togglePlay() }
                playing = clip
            case .video(let url, _):
                if player.isPlaying { player.togglePlay() }
                openURL(url)
            case .search(let url):
                openURL(url)
            case nil:
                openURL(YouTubeSearch.searchURL(artist: track.artistLine, title: track.fullTitle))
            }
        } label: {
            label(result)
        }
        .buttonStyle(.plain)
        .fullScreenCover(item: $playing) { clip in
            ClipPlayerView(clip: clip, fallback: YouTubeSearch.searchURL(artist: track.artistLine, title: track.fullTitle))
        }
        .task(id: track.id) { await ClipFinder.shared.resolve(track, client: session.client) }
    }
}

/// The eye-catching «▶ КЛИП» badge that sits on the cover when a real video was found.
struct ClipBadge: View {
    let track: Track

    var body: some View {
        ClipLauncher(track: track) { result in
            if let result, result.isFound {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill")
                    Text("КЛИП")
                }
                .font(Brand.mono(13, weight: .heavy))
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Brand.acid, in: .capsule)
                .shadow(color: Brand.acid.opacity(0.6), radius: 14)
                .overlay(Capsule().stroke(.black.opacity(0.25), lineWidth: 1))
                .transition(.scale.combined(with: .opacity))
                .symbolEffect(.pulse, options: .repeat(.periodic(delay: 4)))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.4), value: ClipFinder.shared.result(for: track)?.isFound)
        .accessibilityLabel("Смотреть клип")
    }
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
