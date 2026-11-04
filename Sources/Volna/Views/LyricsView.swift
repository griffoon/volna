import SwiftUI

/// Apple Music–style karaoke: the active line sweeps from dim to bright, the rest blur by distance.
struct LyricsView: View {
    @Environment(PlayerEngine.self) private var player
    let lyrics: Lyrics?
    let writers: [String]
    var source: String? = nil

    @State private var userScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    /// How long manual scrolling pauses auto-follow.
    private static let followResumeDelay: Duration = .seconds(3)
    /// Show the "♪" breather before the first line if the intro is longer than this.
    private static let introThreshold = 4.0

    var body: some View {
        switch lyrics {
        case nil:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView("Текста нет", systemImage: "quote.bubble")
                .foregroundStyle(.white.opacity(0.7))
        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                credits
            }
            .scrollIndicators(.hidden)
        case .synced(let lines):
            synced(lines)
        }
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.isPlaying)) { context in
            let now = player.liveElapsed(at: context.date)
            let active = lines.lastIndex { $0.time <= now }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if let first = lines.first, first.time > Self.introThreshold {
                            BreakDots(progress: progress(start: 0, end: first.time, now: now))
                                .opacity(active == nil ? 1 : 0)
                                .frame(height: active == nil ? nil : 0)
                        }
                        ForEach(lines) { line in
                            let index = line.id
                            let end = lines.indices.contains(index + 1) ? lines[index + 1].time : line.time + 5
                            // A real button: taps inside a scroll view reach it reliably, and after
                            // jumping, the lyrics follow the song again right away.
                            Button {
                                Haptics.tick()
                                player.seek(to: line.time)
                                resumeTask?.cancel()
                                withAnimation(.spring(duration: 0.5)) {
                                    userScrolling = false
                                    proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.28))
                                }
                            } label: {
                                LyricLineView(
                                    line: line,
                                    state: lineState(index, active: active),
                                    progress: progress(start: line.time, end: end, now: now),
                                    blur: userScrolling ? 0 : blur(index, active: active)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                        credits
                    }
                    .padding(.vertical, 120)
                }
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        resumeTask?.cancel()
                        userScrolling = true
                    } else if phase == .idle, userScrolling {
                        resumeTask = Task {
                            try? await Task.sleep(for: Self.followResumeDelay)
                            guard !Task.isCancelled else { return }
                            withAnimation { userScrolling = false }
                        }
                    }
                }
                .onChange(of: active) { _, newValue in
                    guard let newValue, !userScrolling else { return }
                    withAnimation(.spring(duration: 0.6, bounce: 0.15)) {
                        proxy.scrollTo(newValue, anchor: UnitPoint(x: 0, y: 0.28))
                    }
                }
                .onAppear {
                    if let active { proxy.scrollTo(active, anchor: UnitPoint(x: 0, y: 0.28)) }
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                        .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var credits: some View {
        if !writers.isEmpty {
            Text("Авторы: " + writers.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 12)
        }
        if let source {
            Text("текст: \(source)")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 4)
        }
    }

    private func lineState(_ index: Int, active: Int?) -> LyricLineView.State {
        guard let active else { return .upcoming }
        if index == active { return .active }
        return index < active ? .past : .upcoming
    }

    private func blur(_ index: Int, active: Int?) -> CGFloat {
        let distance = abs(index - (active ?? -1))
        return min(CGFloat(distance) * 0.9, 3.5)
    }

    private func progress(start: Double, end: Double, now: Double) -> Double {
        guard end > start else { return now >= start ? 1 : 0 }
        return min(max((now - start) / (end - start), 0), 1)
    }
}

private struct LyricLineView: View {
    enum State { case past, active, upcoming }

    let line: LyricLine
    let state: State
    let progress: Double
    let blur: CGFloat

    var body: some View {
        Group {
            if line.isBreak {
                BreakDots(progress: state == .active ? progress : (state == .past ? 1 : 0))
                    .frame(height: state == .active ? nil : 0)
                    .opacity(state == .active ? 1 : 0)
            } else {
                text
            }
        }
        .blur(radius: blur)
        .scaleEffect(state == .active ? 1 : 0.94, anchor: .leading)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: state)
        .contentShape(.rect)
    }

    private var text: some View {
        Text(state == .active ? swept : AttributedString(line.text))
            .font(.system(size: 30, weight: .bold, design: .default))
            .foregroundStyle(.white.opacity(state == .past ? 0.45 : 0.3))
            .shadow(color: .white.opacity(state == .active ? 0.25 : 0), radius: 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The fill goes through the text in reading order, character by character, so a line that
    /// wraps lights up its first row before the second (a left-to-right mask lit both at once).
    /// A few characters of soft edge keep it from looking like a typewriter.
    private var swept: AttributedString {
        var result = AttributedString()
        let characters = Array(line.text)
        let lit = progress * Double(characters.count + Self.softEdge)
        for (index, character) in characters.enumerated() {
            var piece = AttributedString(String(character))
            let amount = min(max((lit - Double(index)) / Double(Self.softEdge), 0), 1)
            piece.foregroundColor = .white.opacity(0.3 + 0.7 * amount)
            result += piece
        }
        return result
    }

    private static let softEdge = 4
}

/// Three pulsing notes shown during instrumental breaks.
private struct BreakDots: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3) { i in
                let lit = progress > Double(i) / 3
                Circle()
                    .fill(.white.opacity(lit ? 0.95 : 0.3))
                    .frame(width: 12, height: 12)
                    .scaleEffect(lit ? 1.15 : 0.85)
                    .animation(.spring(duration: 0.4, bounce: 0.5), value: lit)
            }
        }
        .padding(.vertical, 8)
    }
}
