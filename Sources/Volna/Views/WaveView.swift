import SwiftUI

/// Home: the music-reactive tunnel behind a terminal-style HUD and one acid play button.
struct WaveView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @AppStorage("tunnelASCII") private var ascii = true
    @AppStorage(VisualizerEffect.storageKey) private var effectRaw = VisualizerEffect.smoke.rawValue
    @State private var toast: String?
    @State private var characters: [WaveSettings.Option] = []
    @State private var characterSeeds: Set<String> = []
    /// The tunnel only renders while the hero page is on screen.
    @State private var heroVisible = true
    @State private var showLog = false

    private var scrollHint: some View {
        VStack(spacing: 2) {
            Text("подборки").font(Brand.mono(11, weight: .bold))
            Image(systemName: "chevron.compact.down").font(.system(size: 22, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private var waveIsOn: Bool { player.isWave && player.current != nil }

    private var title: String {
        if case .wave(let title) = player.source, player.current != nil { return title }
        return "Моя волна"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CoverVisualizer(coverURI: player.current?.cover, ascii: ascii, isPlaying: player.isPlaying,
                                active: heroVisible, accent: Theme.shared.accentRGB,
                                effect: VisualizerEffect(rawValue: effectRaw) ?? .smoke,
                                palette: Theme.shared.smokePalette)
                    .ignoresSafeArea()

                // Soft scrim under the text column so labels read over the brightest glyphs.
                RadialGradient(colors: [.black.opacity(0.62), .black.opacity(0)], center: UnitPoint(x: 0.5, y: 0.58),
                               startRadius: 40, endRadius: 280)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    // The smoke is meant to glow behind the title, so it gets no scrim.
                    .opacity(effectRaw == VisualizerEffect.smoke.rawValue ? 0 : 1)

                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            hud
                            Spacer()
                            center
                            Spacer()
                            scrollHint
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 70)
                        .containerRelativeFrame(.vertical)
                        .contentShape(.rect)
                        .onLongPressGesture(minimumDuration: 0.45) {
                            ascii.toggle(); Haptics.thump()
                            flash(ascii ? "> terminal mode: on" : "> terminal mode: off")
                        }

                        HomeSections()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(alignment: .top) {
                                // Fade from the tunnel into the black feed.
                                VStack(spacing: 0) {
                                    LinearGradient(colors: [.clear, Brand.ink], startPoint: .top, endPoint: .bottom)
                                        .frame(height: 140)
                                        .offset(y: -140)
                                    Brand.ink
                                }
                            }
                    }
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top < geo.containerSize.height * 0.85
                } action: { _, visible in
                    heroVisible = visible
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Настройки волны", systemImage: "slider.horizontal.3") {
                        router.destination = .waveSettings
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("волна").font(Brand.display(17)).foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Настройки", systemImage: "gearshape") {
                        router.destination = .settings
                    }
                }
            }
            .task { await loadCharacters() }
        }
    }

    private var hud: some View {
        Button {
            Haptics.tick(); withAnimation(.snappy) { showLog.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.waveTag ?? "sess#---- · idle")
                HStack(spacing: 0) {
                    Text(player.stream.map { "\($0.label) · " } ?? "-- · ")
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
            Menu {
                TrackMenu(track: track)
            } label: {
                ScrambleText(text: track.fullTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.black.opacity(0.45), in: .capsule)
                    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
            }
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

    /// Previous · play · next, with the acid play button in the middle.
    private var transport: some View {
        HStack(spacing: 34) {
            if waveIsOn {
                Button { Haptics.step(); player.goBack() } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 24, weight: .bold))
                }
                .accessibilityLabel("Предыдущий трек")
                .disabled(player.previousTrack == nil)
            }
            PlayPulseButton(isPlaying: waveIsOn && player.isPlaying, isLoading: player.isLoading) {
                if waveIsOn { Haptics.thump(); player.togglePlay() } else { Haptics.launch(); player.startWave() }
            }
            if waveIsOn {
                Button { Haptics.step(); player.next() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 24, weight: .bold))
                }
                .accessibilityLabel("Следующий трек")
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .buttonStyle(.plain)
    }

    /// "Моя волна" until something plays, then the artist — the way Yandex does it.
    private var headline: String {
        guard waveIsOn, let artist = player.current?.artists.first?.name else { return title }
        return artist
    }

    private var center: some View {
        VStack(spacing: 18) {
            Text(headline)
                .font(Brand.display(52))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 18)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: headline)

            if let track = player.current, waveIsOn {
                CoverImage(uri: track.cover, size: 300, corner: 8)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.6), radius: 16)
                    .transition(.scale.combined(with: .opacity))
                trackBar(track)
            }

            transport

            if !characters.isEmpty {
                ViewThatFits(in: .horizontal) {
                    chipRow
                    ScrollView(.horizontal) { chipRow.padding(.horizontal, 2) }
                        .scrollIndicators(.hidden)
                }
            }
        }
    }

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

private struct RoundGlassLabel: View {
    let symbol: String
    var tint: Color = .white

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 50, height: 50)
            .background(.black.opacity(0.45), in: .circle)
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
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
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 34, weight: .heavy))
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
