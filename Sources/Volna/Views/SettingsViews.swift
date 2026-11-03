import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @AppStorage(Preferences.Key.quality) private var quality = Preferences.Quality.high
    @AppStorage(Preferences.Key.crossfade) private var crossfade = 0.0

    var body: some View {
        Form {
            Section {
                Picker("Качество", selection: $quality) {
                    ForEach(Preferences.Quality.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Звук")
            } footer: {
                Text("Lossless нужна подписка Плюс. Если трека нет в FLAC, сыграет лучшее доступное.")
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Кроссфейд")
                        Spacer()
                        Text(crossfade == 0 ? "Выкл, бесшовно" : "\(Int(crossfade)) с")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $crossfade, in: 0...12, step: 1)
                }
            } footer: {
                Text("Следующий трек подгружается заранее, поэтому даже без кроссфейда переход идёт без паузы.")
            }

            Section {
                if let name = session.displayName {
                    LabeledContent("Аккаунт", value: name)
                }
                LabeledContent("Плюс", value: session.hasPlus ? "Есть" : "Нет")
                Button("Выйти", role: .destructive) {
                    router.destination = nil
                    session.logout()
                }
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Mood / character / language for My Wave plus activity stations, all from the server.
struct WaveSettingsView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @State private var settings: WaveSettings?
    @State private var chosen: [String: String] = [:]
    @State private var error: String?

    private static let titles = [
        "diversity": "Характер",
        "moodEnergy": "Настроение",
        "language": "Язык",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let settings {
                    ForEach(restrictionKeys(settings), id: \.self) { key in
                        optionGroup(key, settings.settingRestrictions[key]?.possibleValues ?? [])
                    }
                    ForEach(Array((settings.blocks ?? []).enumerated()), id: \.offset) { _, block in
                        stations(block)
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            if settings == nil, error == nil { ProgressView() }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Preferences.waveSeeds = Array(chosen.values)
                player.startWave()
                router.destination = nil
            } label: {
                Label("Запустить волну", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .navigationTitle("Моя волна")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func restrictionKeys(_ settings: WaveSettings) -> [String] {
        let known = ["moodEnergy", "diversity", "language"]
        let rest = settings.settingRestrictions.keys.filter { !known.contains($0) }.sorted()
        return (known + rest).filter { !(settings.settingRestrictions[$0]?.possibleValues ?? []).isEmpty }
    }

    private func optionGroup(_ key: String, _ options: [WaveSettings.Option]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.titles[key] ?? key).font(.title3.bold())
            ChipFlow(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let selected = isSelected(option, key: key)
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            if option.unspecified == true || option.serializedSeed == nil {
                                chosen[key] = nil
                            } else {
                                chosen[key] = option.serializedSeed
                            }
                        }
                    } label: {
                        Text(option.name).padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    .tint(selected ? .orange : nil)
                    .fontWeight(selected ? .semibold : .regular)
                }
            }
        }
    }

    private func stations(_ block: WaveSettings.Block) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(block.type == "activities" ? "Занятия" : "Волны").font(.title3.bold())
            ChipFlow(spacing: 8) {
                ForEach(block.items ?? [], id: \.self) { station in
                    Button(station.name) {
                        player.startWave(seeds: [station.id.seed], title: station.name)
                        router.destination = nil
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func isSelected(_ option: WaveSettings.Option, key: String) -> Bool {
        if let seed = chosen[key] { return option.serializedSeed == seed }
        return option.unspecified == true
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let loaded = try await client.waveSettings()
            var saved: [String: String] = [:]
            for (key, restriction) in loaded.settingRestrictions {
                let seeds = Set((restriction.possibleValues ?? []).compactMap(\.serializedSeed))
                if let match = Preferences.waveSeeds.first(where: seeds.contains) { saved[key] = match }
            }
            chosen = saved
            settings = loaded
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Wrapping row layout for chips.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
