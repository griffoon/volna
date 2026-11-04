import SwiftUI

/// Tuning My Wave: what's chosen now at the top, each setting explained, every option says what
/// it does, and themed waves (activities, genres…) as a grid you can start right away.
struct WaveSettingsView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @State private var settings: WaveSettings?
    @State private var chosen: [String: String] = [:]
    @State private var error: String?

    private struct Info {
        let title: String
        let symbol: String
        let about: String
    }

    private static let info: [String: Info] = [
        "moodEnergy": Info(title: "Настроение", symbol: "bolt.heart",
                           about: "Какая энергия у треков: от спокойных до тех, под которые хочется двигаться."),
        "diversity": Info(title: "Характер", symbol: "sparkles",
                          about: "Сколько в волне знакомого и сколько нового. Влияет на то, как часто будут попадаться новые для тебя артисты."),
        "language": Info(title: "Язык", symbol: "character.bubble",
                         about: "На каком языке поют. «Без слов» — инструментал, удобно для работы и учёбы."),
    ]

    /// What each option does, matched by its name (the server sends the names, not descriptions).
    private static func hint(for option: WaveSettings.Option) -> (symbol: String, text: String)? {
        let name = option.name.lowercased()
        if option.unspecified == true || name.contains("люб") && !name.contains("любим") {
            return ("circle.dashed", "без ограничений, как обычно")
        }
        let table: [(String, String, String)] = [
            ("бодр", "figure.run", "энергичное, с драйвом"),
            ("весел", "face.smiling", "лёгкое и радостное"),
            ("весёл", "face.smiling", "лёгкое и радостное"),
            ("спокой", "leaf", "мягкое, без резких ударов"),
            ("груст", "cloud.rain", "меланхолия и лирика"),
            ("любим", "heart", "больше того, что ты лайкал"),
            ("незнаком", "binoculars", "новые для тебя артисты"),
            ("популяр", "flame", "хиты и то, что слушают все"),
            ("русск", "textformat", "поют по-русски"),
            ("иностран", "globe", "на других языках"),
            ("без слов", "waveform", "инструментал"),
        ]
        return table.first { name.contains($0.0) }.map { ($0.1, $0.2) }
    }

    private static func stationSymbol(_ station: WaveStation) -> String {
        let tag = (station.id.tag + " " + station.name).lowercased()
        let table: [(String, String)] = [
            ("workout", "figure.run"), ("трениров", "figure.run"), ("sport", "figure.run"),
            ("sleep", "moon.zzz"), ("сон", "moon.zzz"), ("засып", "moon.zzz"),
            ("focus", "brain.head.profile"), ("work", "laptopcomputer"), ("работ", "laptopcomputer"),
            ("study", "book"), ("учеб", "book"), ("учёб", "book"),
            ("road", "car"), ("дорог", "car"), ("drive", "car"),
            ("party", "party.popper"), ("вечерин", "party.popper"),
            ("relax", "cup.and.saucer"), ("отдых", "cup.and.saucer"),
            ("wake", "sunrise"), ("проснуться", "sunrise"), ("утр", "sunrise"),
            ("walk", "figure.walk"), ("прогул", "figure.walk"),
            ("love", "heart"), ("романт", "heart"),
            ("home", "house"), ("дом", "house"),
            ("game", "gamecontroller"), ("игр", "gamecontroller"),
        ]
        return table.first { tag.contains($0.0) }?.1 ?? "dot.radiowaves.left.and.right"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                TerminalHeader(title: "Моя волна", caption: "rotor · настройка")
                summary
                if let settings {
                    ForEach(restrictionKeys(settings), id: \.self) { key in
                        settingCard(key, settings.settingRestrictions[key]?.possibleValues ?? [])
                    }
                    ForEach(Array((settings.blocks ?? []).enumerated()), id: \.offset) { _, block in
                        if let items = block.items, !items.isEmpty { stations(block, items) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .background(Brand.ink)
        .overlay {
            if settings == nil, error == nil { ProgressView().tint(Brand.acid) }
            if let error { ErrorBanner(message: error) { Task { await load() } } }
        }
        .safeAreaInset(edge: .bottom) { launchBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сбросить") {
                    Haptics.tap()
                    withAnimation(.snappy) { chosen = [:] }
                }
                .disabled(chosen.isEmpty)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Summary

    /// One line per setting with the current pick, so the screen answers "what will I get?".
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("> сейчас волна будет такой:")
                .foregroundStyle(.white.opacity(0.55))
            if let settings {
                ForEach(restrictionKeys(settings), id: \.self) { key in
                    HStack(spacing: 0) {
                        Text("  \((Self.info[key]?.title ?? key).lowercased()): ")
                            .foregroundStyle(.white.opacity(0.55))
                        Text(selectedName(key, settings).lowercased())
                            .foregroundStyle(chosen[key] == nil ? .white : Brand.acid)
                            .contentTransition(.opacity)
                    }
                }
            } else {
                Text("  загружаю…").foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(Brand.mono(12, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private func selectedName(_ key: String, _ settings: WaveSettings) -> String {
        let options = settings.settingRestrictions[key]?.possibleValues ?? []
        if let seed = chosen[key], let option = options.first(where: { $0.serializedSeed == seed }) { return option.name }
        return options.first { $0.unspecified == true }?.name ?? "любое"
    }

    // MARK: Settings

    private func restrictionKeys(_ settings: WaveSettings) -> [String] {
        let known = ["moodEnergy", "diversity", "language"]
        let rest = settings.settingRestrictions.keys.filter { !known.contains($0) }.sorted()
        return (known + rest).filter { !(settings.settingRestrictions[$0]?.possibleValues ?? []).isEmpty }
    }

    private func settingCard(_ key: String, _ options: [WaveSettings.Option]) -> some View {
        let info = Self.info[key]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: info?.symbol ?? "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.acid)
                Text(info?.title ?? key)
                    .font(Brand.display(20))
                    .foregroundStyle(.white)
            }
            if let about = info?.about {
                Text(about)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(options, id: \.self) { option in
                    optionTile(option, key: key)
                }
            }
        }
    }

    private func optionTile(_ option: WaveSettings.Option, key: String) -> some View {
        let selected = isSelected(option, key: key)
        let hint = Self.hint(for: option)
        return Button {
            Haptics.tick()
            withAnimation(.spring(duration: 0.3)) {
                if option.unspecified == true || option.serializedSeed == nil {
                    chosen[key] = nil
                } else {
                    chosen[key] = option.serializedSeed
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: hint?.symbol ?? "circle")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .opacity(selected ? 1 : 0.3)
                }
                .foregroundStyle(selected ? Brand.acid : .white.opacity(0.8))
                Text(option.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(hint?.text ?? " ")
                    .font(Brand.mono(10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.acid.opacity(0.12) : .white.opacity(0.04), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Brand.acid : .white.opacity(0.12), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Themed waves

    private func stations(_ block: WaveSettings.Block, _ items: [WaveStation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: block.type == "activities" ? "figure.mixed.cardio" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.acid)
                Text(block.type == "activities" ? "Под занятие" : "Другие волны")
                    .font(Brand.display(20))
                    .foregroundStyle(.white)
            }
            Text(block.type == "activities"
                 ? "Отдельная волна под то, чем ты занят. Запускается сразу, твои настройки выше на неё не влияют."
                 : "Тематические волны. Запускаются сразу.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(items, id: \.self) { station in
                    Button {
                        Haptics.launch()
                        player.startWave(seeds: [station.id.seed], title: station.name)
                        router.destination = nil
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: Self.stationSymbol(station))
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Brand.acid)
                            Text(station.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .padding(.horizontal, 6)
                        .background(.white.opacity(0.04), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Launch

    private var launchBar: some View {
        Button {
            Haptics.launch()
            Preferences.waveSeeds = Array(chosen.values)
            player.startWave()
            router.destination = nil
        } label: {
            VStack(spacing: 2) {
                Label("Запустить мою волну", systemImage: "play.fill")
                    .font(Brand.mono(15, weight: .heavy))
                if !chosen.isEmpty, let settings {
                    Text(restrictionKeys(settings).filter { chosen[$0] != nil }
                            .map { selectedName($0, settings).lowercased() }.joined(separator: " · "))
                        .font(Brand.mono(11, weight: .medium))
                        .lineLimit(1)
                        .opacity(0.75)
                }
            }
            .foregroundStyle(Brand.ink)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Brand.acid, in: .capsule)
            .shadow(color: Brand.acid.opacity(0.4), radius: 16)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
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
