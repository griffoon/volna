import SwiftUI

struct CoverImage: View {
    let uri: String?
    var size: Int = 200
    var corner: CGFloat = 3

    var body: some View {
        AsyncImage(url: CoverURL.make(uri, size: size)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Text("01").font(Brand.mono(11, weight: .bold)).foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: corner))
    }
}

struct TrackRow: View {
    @Environment(PlayerEngine.self) private var player
    let track: Track
    /// Position in an album or playlist; nil shows the cover instead.
    var number: Int?

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if isCurrent {
                        SpectrumText(isPlaying: player.isPlaying, bars: 2)
                    } else {
                        Text(String(format: "%02d", number))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .font(Brand.mono(13, weight: .bold))
                .frame(width: 28, alignment: .leading)
            }
            CoverImage(uri: track.cover, size: 100)
                .frame(width: 46, height: 46)
                .overlay {
                    if isCurrent && number == nil {
                        SpectrumText(isPlaying: player.isPlaying, bars: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.6))
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.fullTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isCurrent ? Brand.acid : .white)
                    .lineLimit(1)
                Text(track.artistLine.lowercased())
                    .font(Brand.mono(12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let ms = track.durationMs {
                Text(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond)))
                    .font(Brand.mono(11))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .contentShape(.rect)
        .opacity(track.available == false ? 0.35 : 1)
    }
}

/// Plays `tracks` starting from the tapped row.
struct TrackList: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    let tracks: [Track]
    var numbered = false
    /// When set (own playlists), a destructive swipe removes the row at that position.
    var onRemove: ((Int) -> Void)?

    var body: some View {
        // Keyed by position: a playlist may hold the same track twice.
        ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
            Button {
                Haptics.tap()
                player.play(tracks, startAt: offset)
            } label: {
                TrackRow(track: track, number: numbered ? offset + 1 : nil)
            }
            .buttonStyle(.plain)
            .terminalRow()
            .contextMenu { TrackMenu(track: track) }
            .swipeActions(edge: .trailing) {
                if let onRemove {
                    Button(role: .destructive) {
                        onRemove(offset)
                    } label: {
                        Label("Убрать", systemImage: "trash")
                    }
                }
                Button {
                    Haptics.success()
                    player.playNext(track)
                } label: {
                    Label("Следующим", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(Brand.acid)
            }
            .swipeActions(edge: .leading) {
                Button {
                    Haptics.success()
                    Task { await session.toggleLike(track) }
                } label: {
                    Label("Лайк", systemImage: session.isLiked(track) ? "heart.slash" : "heart")
                }
                .tint(.pink)
            }
        }
    }
}

// MARK: - Terminal styling

extension View {
    /// Black list row with a hairline separator, the base of every list screen.
    func terminalRow() -> some View {
        listRowBackground(Brand.ink)
            .listRowSeparatorTint(.white.opacity(0.08))
    }

    /// Black page behind a List or ScrollView.
    func terminalPage() -> some View {
        scrollContentBackground(.hidden)
            .background(Brand.ink)
            .listStyle(.plain)
    }
}

/// Big Dela Gothic title with a mono caption line, used at the top of list screens.
struct TerminalHeader: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption {
                Text("> " + caption)
                    .font(Brand.mono(11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(title)
                .font(Brand.display(34))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// Section label like `// плейлисты · 12`.
struct TerminalLabel: View {
    let text: String

    var body: some View {
        Text("// " + text)
            .font(Brand.mono(12, weight: .bold))
            .foregroundStyle(Brand.acid)
            .textCase(nil)
    }
}

/// Primary acid action and secondary outlined action, used under collection headers.
struct TerminalActions: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { Haptics.thump(); play() }) {
                Label("СЛУШАТЬ", systemImage: "play.fill")
                    .font(Brand.mono(13, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(Brand.ink)
                    .background(Brand.acid, in: .capsule)
            }
            Button(action: { Haptics.tap(); shuffle() }) {
                Label("ВПЕРЕМЕШКУ", systemImage: "shuffle")
                    .font(Brand.mono(13, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(.white)
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
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
