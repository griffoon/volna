import SwiftUI

/// Home: the music-reactive tunnel behind a terminal-style HUD and one acid play button.
struct WaveView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @AppStorage("tunnelASCII") private var ascii = true
    @AppStorage(VisualizerEffect.storageKey) private var effectRaw = VisualizerEffect.relief.rawValue
    @State private var toast: String?
    @State private var characters: [WaveSettings.Option] = []
    @State private var characterSeeds: Set<String> = []
    /// The tunnel only renders while the hero page is on screen.
    @State private var heroVisible = true
    @State private var showLog = false
    /// The wave last played on any device, offered when it differs from plain My Wave.
    @State private var lastWave: YMClient.LastWave?
    @State private var scroll = ScrollPosition(edge: .top)
    /// The feed below the hero shows only once you've started scrolling.
    @State private var feedShown = false
    /// Full-screen «режим покоя» with the clock at the bottom.
    @State private var showIdle = false

    /// Small gap kept above the bottom bars; the mini player itself hides while the hero is up.
    private static let miniPlayerHeight: CGFloat = 4
    /// Three mono lines of the collapsed HUD plus its padding.
    private static let hudHeight: CGFloat = 70
    /// From the very top of the screen: the Dynamic Island's own spot.
    private static let islandLabelTop: CGFloat = 13

    private var scrollHint: some View {
        VStack(spacing: 2) {
            Text("подборки").font(Brand.mono(11, weight: .bold))
            Image(systemName: "chevron.compact.down").font(.system(size: 22, weight: .semibold))
                // Every few seconds the arrow nudges downwards as a hint that there's more below.
                .symbolEffect(.bounce.down.byLayer, options: .repeat(.periodic(delay: 3.5)))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var waveIsOn: Bool { player.isWave && player.current != nil }
    private var isWave: Bool { player.isWave }
    /// Plain My Wave (not a wave by a track, artist or album) is what's playing.
    private var isMyWave: Bool { player.source == .wave(title: "Моя волна") }
    /// Any track loaded, from the wave or anywhere else: the screen shows it the same way.
    private var hasTrack: Bool { player.current != nil }

    private var title: String {
        if case .wave(let title) = player.source, player.current != nil { return title }
        return "Моя волна"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.ink.ignoresSafeArea()

                CoverVisualizer(coverURI: player.current?.cover, ascii: ascii, isPlaying: player.isPlaying,
                                active: heroVisible, accent: Theme.shared.accentRGB,
                                effect: VisualizerEffect(rawValue: effectRaw) ?? .relief,
                                palette: Theme.shared.smokePalette)
                    .ignoresSafeArea()
                    // Fully hidden once the feed covers the screen, so it can't peek out at the bottom.
                    .opacity(heroVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: heroVisible)

                // Soft scrim under the text column so labels read over the brightest glyphs.
                RadialGradient(colors: [.black.opacity(0.62), .black.opacity(0)], center: UnitPoint(x: 0.5, y: 0.58),
                               startRadius: 40, endRadius: 280)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    // The smoke is meant to glow behind the title, so it gets no scrim.
                    .opacity(effectRaw == VisualizerEffect.smoke.rawValue ? 0 : 1)

                GeometryReader { geo in
                // The hero fills the whole screen, edge to edge: its content sits between the top
                // bar and the mini player / tab bar, and the feed starts below the bottom edge, so
                // nothing of it shows behind the bars until you scroll.
                let top = geo.safeAreaInsets.top
                // The mini player floats above the tab bar but isn't part of the safe area here,
                // so its height is added by hand while something is loaded.
                let bottom = geo.safeAreaInsets.bottom + (hasTrack ? Self.miniPlayerHeight : 0)
                let available = geo.size.height - (hasTrack ? Self.miniPlayerHeight : 0)
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            // The collapsed HUD's room is reserved; when its log opens it grows over
                            // the screen instead of pushing everything up under the status bar.
                            Color.clear
                                .frame(height: Self.hudHeight)
                                .overlay(alignment: .topLeading) { hud.zIndex(1) }
                                .zIndex(1)
                            Spacer(minLength: 8)
                            center(available: available)
                            Spacer(minLength: 8)
                            scrollHint
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, top + 4)
                        .padding(.bottom, 6)
                        // Ends right at the top of the mini player: the feed follows straight after
                        // «подборки», with no empty screen in between.
                        .frame(height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom - bottom)

                        HomeSections()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Solid black under the whole feed, with a fade sitting just above it so the
                            // visualizer melts into the feed instead of showing through a gap.
                            .background(Brand.ink)
                            .background(alignment: .top) {
                                LinearGradient(colors: [.clear, Brand.ink], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 140)
                                    .offset(y: -140)
                                    .allowsHitTesting(false)
                            }
                            // Tucked away (with its background, so it can't cut the visualizer off)
                            // while the screen sits at the top; slides up as soon as you scroll.
                            .opacity(feedShown ? 1 : 0)
                            .offset(y: feedShown ? 0 : 40)
                            .animation(.spring(duration: 0.45, bounce: 0.15), value: feedShown)
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                // Content runs under the top bar here; without this iOS darkens a band behind it.
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top < geo.containerSize.height * 0.85
                } action: { _, visible in
                    heroVisible = visible
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top > 12
                } action: { _, scrolled in
                    feedShown = scrolled
                    withAnimation(.snappy) { router.waveHeroFocused = !scrolled }
                }
                .onChange(of: router.waveScrollToTop) {
                    Haptics.tick()
                    withAnimation(.spring(duration: 0.5, bounce: 0.15)) { scroll.scrollTo(edge: .top) }
                }
                }

                if let problem = TunnelDiagnostics.shared.message {
                    Text("> metal: \(problem)")
                        .font(Brand.mono(10))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 90)
                        .padding(.horizontal, 12)
                }

                if let toast {
                    Text(toast)
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(Brand.acid)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.85), in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.acid, lineWidth: 1))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 60)
                        .transition(.opacity)
                }
            }
            // The screen's name sits exactly where the Dynamic Island is: on the phone the island
            // covers it, it only shows on screenshots (the way Yandex Market signs its app).
            .overlay {
                VStack {
                    Text("волна")
                        .font(Brand.display(15))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Color(white: 0.22), in: .capsule)
                        .padding(.top, Self.islandLabelTop)
                    Spacer()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .toolbar {
                // My Wave lives top-left: start it, and tune it right next to it.
                ToolbarItem(placement: .topBarLeading) {
                    // A real word on the button: toolbar Labels collapse to their icon, so this
                    // is drawn by hand.
                    Button {
                        Haptics.launch()
                        player.startWave()
                        flash("> моя волна")
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isMyWave ? "waveform" : "dot.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .bold))
                            Text("моя волна")
                                .font(Brand.mono(13, weight: .heavy))
                                .fixedSize()
                        }
                        .foregroundStyle(isMyWave ? Brand.acid : .white)
                        .padding(.horizontal, 6)
                    }
                    .accessibilityLabel("Запустить Мою волну")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Настроить волну", systemImage: "slider.horizontal.3") {
                        Haptics.tap()
                        router.destination = .waveSettings
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Режим покоя", systemImage: "rectangle.expand.diagonal") {
                        Haptics.thump()
                        showIdle = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Устройства", systemImage: Ynison.shared.snapshot.devices.isEmpty ? "hifispeaker" : "hifispeaker.2.fill") {
                        Haptics.tap()
                        router.destination = .devices
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Настройки", systemImage: "gearshape") {
                        router.destination = .settings
                    }
                }
            }
            .fullScreenCover(isPresented: $showIdle) { IdleView() }
            .task {
                await loadCharacters()
                await loadLastWave()
            }
        }
    }

    private var hud: some View {
        Button {
            Haptics.tick(); withAnimation(.snappy) { showLog.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.waveTag ?? "sess#---- | idle")
                HStack(spacing: 0) {
                    Text(player.stream.map { "\($0.label) | " } ?? "-- | ")
                    Text(player.isPlaying ? "buf 30s" : "paused").foregroundStyle(Brand.acid)
                }
                // What was last reported to Yandex; tap the block for the recent history.
                let lines = showLog ? player.reportLog : Array(player.reportLog.suffix(1))
                if lines.isEmpty {
                    Text("> tx: —").foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text("> tx: \(line)")
                        .foregroundStyle(line.hasSuffix("ok") ? Brand.acid : Color(red: 1, green: 0.45, blue: 0.45))
                }
                if showLog { AnalyzerReadout() }
            }
            .font(Brand.mono(11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.78), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Журнал отправки событий")
    }

    /// [dislike] [track pill] [like] [more] — the Yandex row, dislike in plain sight.
    private func trackBar(_ track: Track) -> some View {
        let liked = session.isLiked(track)
        return HStack(spacing: 8) {
            RoundGlassButton(symbol: "heart.slash", label: "Не рекомендовать") {
                Haptics.slam(); Task { await session.dislike(track) }
                flash("> dislike: \(track.title.lowercased())")
            }
            ScrubPill(track: track) { router.playerRequested = true }
            RoundGlassButton(symbol: liked ? "heart.fill" : "heart", label: liked ? "Убрать из любимых" : "Нравится",
                             tint: liked ? Brand.acid : .white) {
                liked ? Haptics.tap() : Haptics.success(); Task { await session.toggleLike(track) }
            }
            Menu {
                TrackMenu(track: track)
            } label: {
                RoundGlassLabel(symbol: "ellipsis", tint: .white)
            }
            .accessibilityLabel("Ещё")
        }
    }

    /// Previous | play | next. Previous and next wear the same outlined rings as like/dislike
    /// above them, so the whole control block reads as one set around the acid play button.
    private var transport: some View {
        HStack(spacing: 26) {
            if hasTrack {
                GlassTransportButton(kind: .previous, size: 60) { Haptics.step(); player.goBack() }
                .accessibilityLabel("Предыдущий трек")
                .disabled(player.previousTrack == nil)
                .opacity(player.previousTrack == nil ? 0.4 : 1)
            }
            PlayPulseButton(isPlaying: hasTrack && player.isPlaying, isLoading: player.isLoading) {
                if hasTrack { Haptics.thump(); player.togglePlay() } else { Haptics.launch(); player.startWave() }
            }
            if hasTrack {
                GlassTransportButton(kind: .next, size: 60) { Haptics.step(); player.next() }
                .accessibilityLabel("Следующий трек")
            }
        }
        .buttonStyle(.plain)
    }

    /// "Моя волна" until something plays, then the artist — the way Yandex does it.
    private var headline: String {
        guard hasTrack, let artist = player.current?.artists.first?.name else { return title }
        return artist
    }

    /// `available` is the height between the top bar and the mini player; the cover shrinks on
    /// shorter screens so everything fits without overlapping the bars.
    private func center(available: CGFloat) -> some View {
        let cover = min(max(available * 0.34, 160), 280)
        return VStack(spacing: 14) {
            Button {
                guard hasTrack, let artist = player.current?.artists.first else { return }
                Haptics.tap()
                router.destination = .artist(id: artist.id.value, name: artist.name)
            } label: {
                Text(headline)
                    .font(Brand.display(available < 640 ? 42 : 50))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 18)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: headline)
                    // The whole line is the target, not just the glyphs.
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(hasTrack ? "Открыть исполнителя" : "")

            if let track = player.current, hasTrack {
                // Same card as in the player: swipe sideways anywhere on this row (beside the cover
                // too) to switch; vertical drags scroll the page.
                CoverDeck(cardSize: cover, onTap: { router.playerRequested = true })
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        ClipBadge(track: track).offset(y: 14)
                    }
                    .transition(.scale.combined(with: .opacity))
                trackBar(track)
            }

            transport

            if !player.isPlaying, let device = Ynison.shared.snapshot.activeDevice,
               !Ynison.shared.snapshot.paused, let other = Ynison.shared.snapshot.current {
                Button {
                    Haptics.tap()
                    router.destination = .devices
                } label: {
                    Label("на \(device.title.lowercased()): \(other.title.lowercased())", systemImage: "hifispeaker.2.fill")
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(.black.opacity(0.6), in: .capsule)
                        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if !hasTrack, let last = lastWave, let seeds = last.seeds, !seeds.isEmpty {
                Button {
                    Haptics.launch()
                    player.startWave(seeds: seeds, title: last.name ?? "Моя волна")
                } label: {
                    Label("продолжить: \(last.name?.lowercased() ?? "прошлая волна")", systemImage: "arrow.uturn.forward")
                        .font(Brand.mono(12, weight: .bold))
                        .foregroundStyle(Brand.acid)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(.black.opacity(0.6), in: .capsule)
                        .overlay(Capsule().stroke(Brand.acid.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            // The character quick-picks only matter while My Wave itself plays; otherwise the
            // top-left buttons start and tune it.
            if hasTrack, isMyWave, !characters.isEmpty {
                ViewThatFits(in: .horizontal) {
                    chipRow
                    ScrollView(.horizontal) { chipRow.padding(.horizontal, 2) }
                        .scrollIndicators(.hidden)
                }
                .transition(.opacity)
            }
        }
    }

    /// Character quick-picks for My Wave (server-provided "diversity" options).
    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(characters, id: \.self) { option in
                let selected = option.serializedSeed.map(characterSeeds.contains) ?? characterSeeds.isEmpty
                Button {
                    Haptics.tick(); pick(option)
                } label: {
                    Text(option.name.lowercased())
                        .font(Brand.mono(11, weight: selected ? .bold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .foregroundStyle(selected ? Brand.acid : .white)
                        .background(.black.opacity(0.8), in: .capsule)
                        .overlay(Capsule().stroke(selected ? Brand.acid : .white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Character chips (server-provided "diversity" options)

    private func loadLastWave() async {
        guard lastWave == nil, let client = session.client, let last = try? await client.lastWave(),
              let seeds = last.seeds, !seeds.isEmpty, seeds != ["user:onyourwave"]
        else { return }
        lastWave = last
    }

    private func loadCharacters() async {
        guard characters.isEmpty, let client = session.client,
              let settings = try? await client.waveSettings(),
              let options = settings.settingRestrictions["diversity"]?.possibleValues
        else { return }
        characters = Array(options.prefix(4))
        let all = Set(options.compactMap(\.serializedSeed))
        characterSeeds = Set(Preferences.waveSeeds.filter(all.contains))
    }

    private func pick(_ option: WaveSettings.Option) {
        let all = Set(characters.compactMap(\.serializedSeed))
        var seeds = Preferences.waveSeeds.filter { !all.contains($0) }
        if option.unspecified != true, let seed = option.serializedSeed { seeds.append(seed) }
        Preferences.waveSeeds = seeds
        characterSeeds = Set(seeds.filter(all.contains))
        flash("> seed: \(option.name.lowercased())")
        if waveIsOn { player.startWave() }
    }

    private func flash(_ message: String) {
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeIn(duration: 0.3)) { if toast == message { toast = nil } }
        }
    }
}

/// Live analyzer state in the expanded HUD: is the tap there, is it in sync, what it hears.
private struct AnalyzerReadout: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { _ in
            let d = AudioAnalyzer.shared.diagnostics()
            let l = AudioAnalyzer.shared.snapshot()
            VStack(alignment: .leading, spacing: 4) {
                Text("> fft: taps \(d.tapsAttached) | \(Int(d.sampleRate)) Hz | \(d.format)")
                Text("> sync: \(d.synced ? "ok" : "нет кадров") | опережение \(String(format: "%.2f", d.lead)) с")
                    .foregroundStyle(d.synced ? Brand.acid : Color(red: 1, green: 0.45, blue: 0.45))
                Text("> бас \(Self.bar(l.bass)) \(Self.hit(l.bassHit))")
                Text("> мид \(Self.bar(l.mid)) \(Self.hit(l.midHit))")
                Text("> хай \(Self.bar(l.high)) \(Self.hit(l.highHit))")
            }
        }
    }

    private static func bar(_ value: Float) -> String {
        let filled = Int((min(max(value, 0), 1) * 12).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "-", count: 12 - filled)
    }

    private static func hit(_ value: Float) -> String { value > 0.3 ? "◆" : "◇" }
}

struct RoundGlassLabel: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 50
    var iconSize: CGFloat = 18

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .contentShape(.circle)
            .contentLayerControl(in: Circle())
    }
}

extension View {
    /// Controls that sit in the content (track buttons, chips, the scrubber) use a standard thin
    /// material, not Liquid Glass: Apple keeps glass for the floating navigation layer (tab bar,
    /// toolbars, mini player), and glass over the busy visualizer warped into blobs.
    func contentLayerControl<S: Shape>(in shape: S, highlighted: Bool = false) -> some View {
        background(.ultraThinMaterial.opacity(0.9), in: shape)
            .background(.black.opacity(0.35), in: shape)
            .overlay(shape.stroke(highlighted ? Brand.acid : .white.opacity(0.18), lineWidth: 1))
    }
}

private struct RoundGlassButton: View {
    let symbol: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundGlassLabel(symbol: symbol, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

/// Acid play button that thumps on detected beats.
private struct PlayPulseButton: View {
    let isPlaying: Bool
    let isLoading: Bool
    let action: () -> Void
    @State private var lastBeat: UInt64 = 0
    @State private var kickAt = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { context in
            let levels = AudioAnalyzer.shared.snapshot()
            let kick = max(0, 1 - context.date.timeIntervalSince(kickAt) * 5)
            Button(action: action) {
                Group {
                    if isLoading {
                        ProgressView().tint(Brand.ink)
                    } else {
                        TransportGlyph.icon(isPlaying ? .pause : .play, height: 30)
                            .offset(x: isPlaying ? 0 : 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: isPlaying)
                .foregroundStyle(Brand.ink)
                .frame(width: 96, height: 96)
                .background(Brand.acid, in: .circle)
                .shadow(color: Brand.acid.opacity(0.45), radius: 20 + kick * 30)
                .scaleEffect(1 + kick * 0.06)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Пауза" : "Играть Мою волну")
            .onChange(of: levels.beat) { _, beat in
                if beat != lastBeat { lastBeat = beat; kickAt = context.date }
            }
        }
    }
}

/// The track title pill doubles as a seek bar: its fill shows how far the track is, sliding
/// a finger sideways scrubs (the title turns into the time), a tap opens the full player.
private struct ScrubPill: View {
    @Environment(PlayerEngine.self) private var player
    let track: Track
    let open: () -> Void
    /// Fraction being scrubbed to; nil when not dragging.
    @State private var scrub: Double?
    @State private var startFraction: Double = 0

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1 / 15, paused: !player.isPlaying || scrub != nil)) { context in
                let fraction = scrub ?? playedFraction(at: context.date)
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.45))
                    Rectangle()
                        .fill(Brand.acid.opacity(scrub == nil ? 0.16 : 0.32))
                        .frame(width: geo.size.width * fraction)
                    Group {
                        if let scrub {
                            Text("\(Self.time(scrub * player.duration)) / \(Self.time(player.duration))")
                                .font(Brand.mono(15, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Brand.acid)
                        } else {
                            ScrambleText(text: track.fullTitle)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                }
                .clipShape(.capsule)
                .overlay(Capsule().stroke(scrub == nil ? .white.opacity(0.15) : Brand.acid, lineWidth: 1))
            }
            .contentShape(.capsule)
            .onTapGesture { Haptics.tap(); open() }
            .gesture(HorizontalPan(
                onBegan: {
                    startFraction = playedFraction(at: .now)
                    Haptics.tick()
                },
                onChanged: { value in
                    guard player.duration > 0 else { return }
                    let next = min(max(startFraction + value.translation / geo.size.width, 0), 1)
                    // A soft click every 10 seconds of track.
                    if let scrub, Int(scrub * player.duration / 10) != Int(next * player.duration / 10) { Haptics.tick() }
                    scrub = next
                },
                onEnded: { _ in
                    defer { scrub = nil }
                    guard let scrub, player.duration > 0 else { return }
                    Haptics.step()
                    player.seek(to: scrub * player.duration)
                }
            ))
        }
        .frame(height: 50)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.fullTitle)
        .accessibilityHint("Свайп вбок — перемотка, тап — открыть плеер")
        .accessibilityAdjustableAction { direction in
            guard player.duration > 0 else { return }
            let step = direction == .increment ? 10.0 : -10.0
            player.seek(to: min(max(player.elapsed + step, 0), player.duration))
        }
    }

    private func playedFraction(at date: Date) -> Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.liveElapsed(at: date) / player.duration, 0), 1)
    }

    private static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
