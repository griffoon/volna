import SwiftUI

/// Tuning My Wave on one screen. Our living visualizer glows behind; the headline says what wave
/// you'll get; three glass drums (mood, character, language) spin sideways under your thumb and
/// whatever lands in the lit window is picked. Activity waves sit below as chips.
struct WaveSettingsView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @State private var settings: WaveSettings?
    /// Chosen option index per setting; -1 (or absent) is "любое".
    @State private var picks: [String: Int] = [:]
    @State private var error: String?

    private static let titles = ["moodEnergy": "настроение", "diversity": "характер", "language": "язык"]

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            CoverVisualizer(coverURI: player.current?.cover, ascii: true, isPlaying: player.isPlaying,
                            accent: Theme.shared.accentRGB, effect: .smoke, palette: Theme.shared.smokePalette)
                .ignoresSafeArea()
                .opacity(0.55)
                .allowsHitTesting(false)
            LinearGradient(colors: [Brand.ink.opacity(0.2), Brand.ink.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                headline
                Spacer(minLength: 12)
                if let settings {
                    Group {
                        VStack(spacing: 22) {
                            ForEach(rows(settings), id: \.key) { row in
                                SettingDrum(title: row.title, options: row.options,
                                            selection: Binding(get: { picks[row.key] ?? -1 },
                                                               set: { picks[row.key] = $0 }))
                            }
                        }
                    }
                } else if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    ProgressView().tint(Brand.acid)
                }
                Spacer(minLength: 12)
                if let settings { activities(settings) }
                launchButton.padding(.top, 14)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сбросить", systemImage: "arrow.counterclockwise") {
                    Haptics.tap()
                    withAnimation(.spring(duration: 0.4, bounce: 0.3)) { picks = [:] }
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Headline

    /// What you'll get, big: «ВЕСЁЛОЕ | ЛЮБИМОЕ» or just «МОЯ ВОЛНА» when nothing is narrowed.
    private var headline: some View {
        VStack(spacing: 6) {
            Text("> моя волна будет")
                .font(Brand.mono(12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(summary.uppercased())
                .font(Brand.display(30))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.snappy, value: summary)
                .shadow(color: Brand.acid.opacity(0.35), radius: 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var summary: String {
        guard let settings else { return " " }
        let parts = rows(settings).compactMap { row -> String? in
            guard let index = picks[row.key], row.options.indices.contains(index) else { return nil }
            return row.options[index].name.lowercased()
        }
        return parts.isEmpty ? "как обычно" : parts.joined(separator: " | ")
    }

    // MARK: Rows

    private struct Row {
        let key: String
        let title: String
        let options: [WaveSettings.Option]
    }

    private func rows(_ settings: WaveSettings) -> [Row] {
        let known = ["moodEnergy", "diversity", "language"]
        let rest = settings.settingRestrictions.keys.filter { !known.contains($0) }.sorted()
        return (known + rest).compactMap { key in
            let options = (settings.settingRestrictions[key]?.possibleValues ?? [])
                .filter { $0.unspecified != true && $0.serializedSeed != nil }
            guard !options.isEmpty else { return nil }
            return Row(key: key, title: Self.titles[key] ?? key.lowercased(), options: options)
        }
    }

    // MARK: Activities

    private func activities(_ settings: WaveSettings) -> some View {
        let stations = (settings.blocks ?? []).flatMap { $0.items ?? [] }
        return VStack(alignment: .leading, spacing: 8) {
            if !stations.isEmpty {
                Text("> или сразу под занятие")
                    .font(Brand.mono(11))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 4)
                ScrollView(.horizontal) {
                    Group {
                        HStack(spacing: 8) {
                            ForEach(stations, id: \.self) { station in
                                Button {
                                    Haptics.launch()
                                    player.startWave(seeds: [station.id.seed], title: station.name)
                                    router.destination = nil
                                } label: {
                                    Label(station.name.lowercased(), systemImage: Self.stationSymbol(station))
                                        .font(Brand.mono(12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .frame(height: 40)
                                        .contentLayerControl(in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private static func stationSymbol(_ station: WaveStation) -> String {
        let tag = (station.id.tag + " " + station.name).lowercased()
        let table: [(String, String)] = [
            ("workout", "figure.run"), ("трениров", "figure.run"), ("sport", "figure.run"),
            ("sleep", "moon.zzz"), ("сон", "moon.zzz"), ("засып", "moon.zzz"),
            ("focus", "brain.head.profile"), ("work", "laptopcomputer"), ("работ", "laptopcomputer"),
            ("study", "book"), ("учеб", "book"), ("учёб", "book"),
            ("road", "car"), ("дорог", "car"), ("drive", "car"),
            ("party", "party.popper"), ("вечерин", "party.popper"), ("танц", "figure.dance"),
            ("relax", "cup.and.saucer"), ("отдых", "cup.and.saucer"),
            ("wake", "sunrise"), ("просып", "sunrise"), ("утр", "sunrise"),
            ("walk", "figure.walk"), ("прогул", "figure.walk"),
            ("love", "heart"), ("романт", "heart"),
            ("game", "gamecontroller"), ("игр", "gamecontroller"),
        ]
        return table.first { tag.contains($0.0) }?.1 ?? "dot.radiowaves.left.and.right"
    }

    // MARK: Launch

    private var launchButton: some View {
        Button {
            Haptics.launch()
            if let settings {
                Preferences.waveSeeds = rows(settings).compactMap { row in
                    picks[row.key].flatMap { row.options.indices.contains($0) ? row.options[$0].serializedSeed : nil }
                }
            }
            player.startWave()
            router.destination = nil
        } label: {
            HStack(spacing: 10) {
                TransportGlyph.icon(.play, height: 16)
                Text("запустить").font(Brand.mono(15, weight: .heavy))
            }
            .foregroundStyle(Brand.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Brand.acid, in: .capsule)
            .shadow(color: Brand.acid.opacity(0.45), radius: 18)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let loaded = try await client.waveSettings()
            var saved: [String: Int] = [:]
            for row in rows(loaded) {
                if let index = row.options.firstIndex(where: { Preferences.waveSeeds.contains($0.serializedSeed ?? "") }) {
                    saved[row.key] = index
                }
            }
            picks = saved
            settings = loaded
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One setting as a sideways drum: options slide under a lit window in the middle;
/// what stops in the window is the pick. «любое» is always the first stop.
private struct SettingDrum: View {
    let title: String
    let options: [WaveSettings.Option]
    /// -1 means «любое».
    @Binding var selection: Int
    @State private var centred: Int?

    private static let slot: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(Brand.display(15))
                    .foregroundStyle(.white)
                Spacer()
                Text("← свайп →")
                    .font(Brand.mono(10))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 6)
            GeometryReader { geo in
                ZStack {
                    // The lit window the picked option lands in.
                    Capsule()
                        .fill(.clear)
                        .frame(width: Self.slot, height: 48)
                        .contentLayerControl(in: Capsule(), highlighted: true)
                        .background(Brand.acid.opacity(0.14), in: .capsule)

                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(-1..<options.count, id: \.self) { index in
                                let isPicked = (centred ?? selection) == index
                                Text(index < 0 ? "любое" : options[index].name.lowercased())
                                    .font(Brand.mono(isPicked ? 15 : 13, weight: isPicked ? .heavy : .medium))
                                    .foregroundStyle(isPicked ? Brand.acid : .white.opacity(0.75))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(width: Self.slot, height: 48)
                                    .contentShape(.rect)
                                    .onTapGesture {
                                        withAnimation(.snappy) { centred = index }
                                    }
                                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                        content
                                            .opacity(1 - min(abs(phase.value), 1) * 0.55)
                                            .scaleEffect(1 - min(abs(phase.value), 1) * 0.12)
                                            .blur(radius: abs(phase.value) * 1.2)
                                    }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .contentMargins(.horizontal, (geo.size.width - Self.slot) / 2, for: .scrollContent)
                    .scrollPosition(id: $centred, anchor: .center)
                    .scrollIndicators(.hidden)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                }
            }
            .frame(height: 48)
        }
        .onAppear { centred = selection }
        .onChange(of: selection) { _, value in if centred != value { withAnimation(.snappy) { centred = value } } }
        .onChange(of: centred) { _, value in
            guard let value, value != selection else { return }
            Haptics.tick()
            selection = value
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selection < 0 ? "любое" : options[selection].name)
        .accessibilityAdjustableAction { direction in
            selection = direction == .increment ? min(selection + 1, options.count - 1) : max(selection - 1, -1)
        }
    }
}
