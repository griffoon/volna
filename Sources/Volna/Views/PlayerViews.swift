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
                Text(player.current?.fullTitle ?? "Ничего не играет")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let artist = player.current?.artistLine {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
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
    }
}

struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @State private var scrubbing: Double?
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var lyrics = LyricsLoader()
    @Namespace private var coverSpace

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 24) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)

                if showLyrics {
                    HStack(spacing: 14) {
                        CoverImage(uri: player.current?.cover, size: 200, corner: 8)
                            .matchedGeometryEffect(id: "cover", in: coverSpace)
                            .frame(width: 60, height: 60)
                        titleRow
                    }
                    LyricsView(lyrics: lyrics.lyrics, writers: lyrics.writers)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                    CoverImage(uri: player.current?.cover, size: 800, corner: 18)
                        .matchedGeometryEffect(id: "cover", in: coverSpace)
                        .padding(.horizontal, 28)
                        .scaleEffect(player.isPlaying ? 1 : 0.86)
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
                        .animation(.spring(duration: 0.5, bounce: 0.35), value: player.isPlaying)
                    Spacer(minLength: 0)
                    titleRow
                }

                progress
                controls
                bottomBar
            }
            .padding(.horizontal, 24)
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $showQueue) {
            QueueView().presentationDetents([.medium, .large])
        }
        .task(id: player.current?.id) {
            guard let track = player.current else { return }
            await lyrics.load(track, client: session.client)
        }
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                Button {
                    withAnimation(.spring(duration: 0.55, bounce: 0.2)) { showLyrics.toggle() }
                } label: {
                    Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .frame(width: 52, height: 44)
                }
                .glassEffect(showLyrics ? .regular.tint(.white.opacity(0.25)).interactive() : .regular.interactive(),
                             in: .capsule)

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet").frame(width: 52, height: 44)
                }
                .glassEffect(.regular.interactive(), in: .capsule)

                Menu {
                    sleepMenu
                } label: {
                    Image(systemName: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
                        .frame(width: 52, height: 44)
                }
                .glassEffect(player.sleepTimer == nil ? .regular.interactive()
                             : .regular.tint(.white.opacity(0.25)).interactive(), in: .capsule)

                if let track = player.current {
                    Menu {
                        TrackMenu(track: track)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 52, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding(.bottom, 12)
    }

    private var backdrop: some View {
        CoverImage(uri: player.current?.cover, size: 200, corner: 0)
            .scaleEffect(2.4)
            .blur(radius: 70)
            .overlay(.black.opacity(0.35))
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: player.current?.id)
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

    private var titleRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.fullTitle ?? "—").font(.title2.bold()).lineLimit(1)
                Text(player.current?.artistLine ?? "").font(.title3).opacity(0.7).lineLimit(1)
            }
            Spacer()
            if let track = player.current {
                let liked = session.isLiked(track)
                Button {
                    Task { await session.toggleLike(track) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(liked ? .pink : .white)
                        .symbolEffect(.bounce, value: liked)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }

    private var progress: some View {
        let total = max(player.duration, 1)
        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.elapsed },
                    set: { scrubbing = $0 }
                ),
                in: 0...total
            ) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            .tint(.white)
            HStack {
                Text(format(scrubbing ?? player.elapsed))
                Spacer()
                Text("-" + format(total - (scrubbing ?? player.elapsed)))
            }
            .font(.caption.monospacedDigit())
            .opacity(0.6)
        }
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 20) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").frame(width: 64, height: 64)
                }
                .glassEffect(.regular.interactive(), in: .circle)

                Button { player.togglePlay() } label: {
                    Group {
                        if player.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.largeTitle)
                    .frame(width: 88, height: 88)
                }
                .glassEffect(.regular.tint(.orange.opacity(0.35)).interactive(), in: .circle)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill").frame(width: 64, height: 64)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .font(.title)
            .buttonStyle(.plain)
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
                    Section("Сейчас") { TrackRow(track: current) }
                }
                Section("Далее") {
                    ForEach(Array(player.upNext), id: \.id) { track in
                        Button { player.jump(to: track) } label: { TrackRow(track: track) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
