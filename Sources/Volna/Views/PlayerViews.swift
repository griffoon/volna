import SwiftUI

/// Lives in the tab bar accessory slot, so it gets the system Liquid Glass capsule for free.
struct MiniPlayer: View {
    @Environment(PlayerEngine.self) private var player
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(uri: player.current?.cover, size: 100, corner: 6)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                ScrambleText(text: player.current?.fullTitle ?? "Ничего не играет", duration: 0.4)
                    .font(Brand.mono(13, weight: .bold))
                    .lineLimit(1)
                if let artist = player.current?.artistLine {
                    Text(artist).font(Brand.mono(11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            SpectrumText(isPlaying: player.isPlaying)
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(player.current == nil)
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(player.current == nil)
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture { if player.current != nil { open() } }
        .modifier(MiniPlayerSwipe())
    }
}

struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var pickArtist = false
    @Environment(Router.self) private var router
    @State private var lyrics = LyricsLoader()
    @Namespace private var coverSpace

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 22) {
                Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 10)

                HStack {
                    Text(player.stream.map { "> \($0.label.lowercased())" } ?? "> buffering…")
                    Spacer()
                    SpectrumText(isPlaying: player.isPlaying)
                }
                .font(Brand.mono(11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

                if showLyrics {
                    HStack(spacing: 14) {
                        CoverImage(uri: player.current?.cover, size: 200)
                            .matchedGeometryEffect(id: "cover", in: coverSpace)
                            .frame(width: 60, height: 60)
                        titleRow
                    }
                    LyricsView(lyrics: lyrics.lyrics, writers: lyrics.writers)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                    CoverDeck()
                        .matchedGeometryEffect(id: "cover", in: coverSpace)
                        .padding(.horizontal, 32)
                    Spacer(minLength: 0)
                    titleRow
                }

                TerminalScrubber(elapsed: player.elapsed, duration: player.duration) { player.seek(to: $0) }
                controls
                actions
            }
            .padding(.horizontal, 24)
            .foregroundStyle(.white)
        }
        .presentationBackground(Brand.ink)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationBackground(Brand.ink)
        }
        .task(id: player.current?.id) {
            guard let track = player.current else { return }
            await lyrics.load(track, client: session.client)
        }
    }

    private var backdrop: some View {
        ZStack {
            Brand.ink
            AsciiCover(uri: player.current?.cover)
                .foregroundStyle(.white.opacity(showLyrics ? 0.08 : 0.2))
                .animation(.easeInOut(duration: 0.4), value: showLyrics)
            LinearGradient(colors: [.clear, Brand.ink.opacity(0.9)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if let album = player.current?.albums?.first { router.destination = .album(album) }
                } label: {
                    ScrambleText(text: player.current?.fullTitle ?? "—")
                        .font(Brand.display(26))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .accessibilityHint("Открыть релиз")
                Button {
                    guard let artists = player.current?.artists, !artists.isEmpty else { return }
                    if artists.count == 1 {
                        router.destination = .artist(id: artists[0].id.value, name: artists[0].name)
                    } else {
                        pickArtist = true
                    }
                } label: {
                    Text((player.current?.artistLine ?? "").lowercased())
                        .font(Brand.mono(14))
                        .opacity(0.6)
                        .lineLimit(1)
                }
                .accessibilityHint("Открыть исполнителя")
            }
            .buttonStyle(.plain)
            .confirmationDialog("Исполнитель", isPresented: $pickArtist, titleVisibility: .visible) {
                ForEach(player.current?.artists ?? []) { artist in
                    Button(artist.name) { router.destination = .artist(id: artist.id.value, name: artist.name) }
                }
            }
            Spacer()
            if let track = player.current {
                let liked = session.isLiked(track)
                Button {
                    Task { await session.toggleLike(track) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(liked ? Brand.acid : .white.opacity(0.8))
                        .symbolEffect(.bounce, value: liked)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liked ? "Убрать из любимых" : "Нравится")
            }
        }
    }

    private var controls: some View {
        HStack {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").frame(width: 64, height: 64)
            }
            .accessibilityLabel("Назад")
            Spacer()
            Button { player.togglePlay() } label: {
                Group {
                    if player.isLoading {
                        ProgressView().tint(Brand.ink)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(Brand.ink)
                .frame(width: 88, height: 88)
                .background(Brand.acid, in: .circle)
                .shadow(color: Brand.acid.opacity(0.35), radius: 24)
            }
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").frame(width: 64, height: 64)
            }
            .accessibilityLabel("Дальше")
        }
        .font(.system(size: 30, weight: .bold))
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private var actions: some View {
        HStack {
            ActionItem(symbol: showLyrics ? "quote.bubble.fill" : "quote.bubble", label: "текст", active: showLyrics) {
                withAnimation(.spring(duration: 0.55, bounce: 0.2)) { showLyrics.toggle() }
            }
            Spacer()
            ActionItem(symbol: "list.bullet", label: "очередь", active: false) { showQueue = true }
            Spacer()
            Menu {
                sleepMenu
            } label: {
                ActionLabel(symbol: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill", label: "сон",
                            active: player.sleepTimer != nil)
            }
            Spacer()
            if let track = player.current {
                Menu {
                    TrackMenu(track: track)
                } label: {
                    ActionLabel(symbol: "ellipsis", label: "ещё", active: false)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var sleepMenu: some View {
        if let timer = player.sleepTimer {
            switch timer {
            case .at(let date):
                Text("Выключится в \(date.formatted(date: .omitted, time: .shortened))")
            case .endOfTrack:
                Text("Выключится после трека")
            }
            Button("Отменить таймер", systemImage: "xmark", role: .destructive) { player.setSleepTimer(nil) }
        }
        Section("Таймер сна") {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) мин") { player.setSleepTimer(.at(.now.addingTimeInterval(Double(minutes) * 60))) }
            }
            Button("В конце трека", systemImage: "music.note") { player.setSleepTimer(.endOfTrack) }
        }
    }
}

private struct ActionLabel: View {
    let symbol: String
    let label: String
    let active: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium))
            Text(label).font(Brand.mono(10, weight: .medium))
        }
        .foregroundStyle(active ? Brand.acid : .white.opacity(0.65))
        .frame(minWidth: 56, minHeight: 48)
        .contentShape(.rect)
    }
}

private struct ActionItem: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { ActionLabel(symbol: symbol, label: label, active: active) }
    }
}

/// Thin acid progress line with a narrow marker; drag anywhere to scrub.
struct TerminalScrubber: View {
    let elapsed: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        let total = max(duration, 1)
        let shown = dragging ?? elapsed
        VStack(spacing: 8) {
            GeometryReader { geo in
                let x = geo.size.width * CGFloat(min(max(shown / total, 0), 1))
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 2)
                    Rectangle().fill(Brand.acid).frame(width: x, height: 2)
                    Rectangle().fill(Brand.acid)
                        .frame(width: 3, height: dragging == nil ? 14 : 22)
                        .offset(x: max(0, x - 1.5))
                        .animation(.spring(duration: 0.2), value: dragging == nil)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = Double(min(max(value.location.x / geo.size.width, 0), 1)) * total
                        }
                        .onEnded { _ in
                            if let target = dragging { onSeek(target) }
                            dragging = nil
                        }
                )
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel("Позиция")
            .accessibilityValue(format(shown))
            .accessibilityAdjustableAction { direction in
                onSeek(direction == .increment ? min(elapsed + 10, total) : max(elapsed - 10, 0))
            }

            HStack {
                Text(format(shown))
                Spacer()
                Text("-" + format(total - shown))
            }
            .font(Brand.mono(11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

struct QueueView: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section {
                        TrackRow(track: current).terminalRow()
                    } header: {
                        TerminalLabel(text: "сейчас")
                    }
                }
                Section {
                    ForEach(Array(player.upNext.enumerated()), id: \.element.id) { offset, track in
                        Button { player.jump(to: track) } label: { TrackRow(track: track, number: offset + 1) }
                            .buttonStyle(.plain)
                            .terminalRow()
                    }
                } header: {
                    TerminalLabel(text: "далее · \(player.upNext.count)")
                }
            }
            .terminalPage()
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
