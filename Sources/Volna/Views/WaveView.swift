import SwiftUI

struct WaveView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router

    private var title: String {
        if case .wave(let title) = player.source, player.current != nil { return title }
        return "Моя волна"
    }

    private var waveIsOn: Bool { player.isWave && player.current != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()

                VStack(spacing: 32) {
                    Spacer()

                    Button {
                        if waveIsOn { player.togglePlay() } else { player.startWave() }
                    } label: {
                        Image(systemName: waveIsOn && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 54, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 150, height: 150)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.tint(.orange.opacity(0.3)).interactive(), in: .circle)
                    .scaleEffect(player.isLoading ? 0.94 : 1)
                    .animation(.spring(duration: 0.4, bounce: 0.4), value: player.isLoading)

                    VStack(spacing: 6) {
                        Text(title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(.white)

                    Spacer()

                    if waveIsOn {
                        HStack(spacing: 20) {
                            Button("Дальше", systemImage: "forward.fill") { player.next() }
                            if let track = player.current {
                                Button(
                                    "Лайк",
                                    systemImage: session.isLiked(track) ? "heart.fill" : "heart"
                                ) {
                                    Task { await session.toggleLike(track) }
                                }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.bottom, 40)
                .animation(.smooth, value: waveIsOn)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Настройки волны", systemImage: "slider.horizontal.3") {
                        router.destination = .waveSettings
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Настройки", systemImage: "gearshape") {
                        router.destination = .settings
                    }
                }
            }
        }
    }

    private var subtitle: String {
        if player.isLoading && player.current == nil { return "Подбираем…" }
        guard waveIsOn, let track = player.current else { return "Нажми и слушай" }
        return "\(track.fullTitle) — \(track.artistLine)"
    }
}
