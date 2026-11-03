import SwiftUI

struct CoverImage: View {
    let uri: String?
    var size: Int = 200
    var corner: CGFloat = 8

    var body: some View {
        AsyncImage(url: CoverURL.make(uri, size: size)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
    }
}

struct TrackRow: View {
    @Environment(PlayerEngine.self) private var player
    let track: Track

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(uri: track.cover, size: 100, corner: 6)
                .frame(width: 48, height: 48)
                .overlay {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.4), in: .rect(cornerRadius: 6))
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.fullTitle)
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(track.artistLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let ms = track.durationMs {
                Text(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .opacity(track.available == false ? 0.4 : 1)
    }
}

/// Plays `tracks` starting from the tapped row.
struct TrackList: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    let tracks: [Track]

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
            Button {
                player.play(tracks, startAt: offset)
            } label: {
                TrackRow(track: track)
            }
            .buttonStyle(.plain)
            .contextMenu { TrackMenu(track: track) }
            .swipeActions(edge: .trailing) {
                Button {
                    player.playNext(track)
                } label: {
                    Label("Следующим", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await session.toggleLike(track) }
                } label: {
                    Label("Лайк", systemImage: session.isLiked(track) ? "heart.slash" : "heart")
                }
                .tint(.pink)
            }
        }
    }
}

/// Slow-moving warm gradient used behind hero areas.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.5 + 0.2 * sin(t / 3)), Float(0.5 + 0.15 * cos(t / 4))], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    .black, .indigo, .black,
                    .orange, .pink, .purple,
                    .black, .red.opacity(0.8), .black,
                ]
            )
        }
        .ignoresSafeArea()
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Не загрузилось", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Повторить", action: retry).buttonStyle(.glass)
        }
    }
}
