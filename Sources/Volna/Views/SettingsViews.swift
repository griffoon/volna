import SwiftUI

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @AppStorage(Preferences.Key.quality) private var quality = Preferences.Quality.high
    @AppStorage(Preferences.Key.crossfade) private var crossfade = 0.0
    @AppStorage(Theme.coverAccentKey) private var coverAccent = true
    @AppStorage(HapticBass.storageKey) private var hapticBass = false
    @AppStorage(HapticBass.offsetKey) private var hapticOffset = 0.0
    @AppStorage(KickBounce.storageKey) private var coverBounce = true
    @AppStorage(VisualizerEffect.storageKey) private var effectRaw = VisualizerEffect.smoke.rawValue
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Form {
            Section {
                Picker("Качество", selection: $quality) {
                    ForEach(Preferences.Quality.allCases) { Text($0.title).tag($0) }
                }
                NavigationLink {
                    EqualizerView()
                } label: {
                    LabeledContent("Эквалайзер и громкость",
                                   value: AudioProcessing.shared.snapshot().eqEnabled ? "вкл" : "выкл")
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
                Picker("Визуализатор", selection: $effectRaw) {
                    ForEach(VisualizerEffect.allCases) { effect in
                        VStack(alignment: .leading) {
                            Text(effect.title)
                            Text(effect.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(effect.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Визуализатор «Волны»")
            }

            Section {
                Toggle("Тактильный бас", isOn: $hapticBass)
                    .tint(Brand.acid)
                if hapticBass {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Сдвиг вибрации", value: hapticOffset == 0 ? "0 мс" : String(format: "%+.0f мс", hapticOffset))
                        Slider(value: $hapticOffset, in: HapticBass.offsetRange, step: 5)
                            .tint(Brand.acid)
                            .onChange(of: hapticOffset) { Haptics.tick() }
                    }
                }
                Toggle("Обложка в такт", isOn: $coverBounce)
                    .tint(Brand.acid)
                Toggle("Акцент из обложки", isOn: $coverAccent)
                    .tint(Brand.acid)
                    .onChange(of: coverAccent) {
                        Task { await Theme.shared.update(coverURI: player.current?.cover) }
                    }
            } header: {
                Text("Вид")
            } footer: {
                Text("Бас и прыжки визуализатора идут по бочке (самые низкие частоты). Если вибрация спешит или опаздывает — подвинь ползунок. Цвет кнопок и подсветки берётся из обложки текущего трека.")
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

/// 10-band equalizer applied inside the audio tap; changes are heard immediately.
struct EqualizerView: View {
    @State private var state = AudioProcessing.shared.snapshot()

    var body: some View {
        List {
            Section {
                Toggle("Эквалайзер", isOn: Binding(
                    get: { state.eqEnabled },
                    set: { value in Haptics.tick(); apply { $0.eqEnabled = value } }
                ))
                .tint(Brand.acid)
                Toggle("Выравнивать громкость", isOn: Binding(
                    get: { state.normalize },
                    set: { value in Haptics.tick(); apply { $0.normalize = value } }
                ))
                .tint(Brand.acid)
            } footer: {
                Text("Выравнивание подтягивает каждый трек к −14 LUFS по данным Яндекса, без перегруза. Действует со следующего трека.")
            }
            .terminalRow()

            Section(header: TerminalLabel(text: "пресеты")) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(EQPreset.allCases) { preset in
                            let active = state.gains == preset.gains
                            Button(preset.title.lowercased()) {
                                Haptics.tick()
                                apply { $0.gains = preset.gains; $0.eqEnabled = true }
                            }
                            .font(Brand.mono(12, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? Brand.acid : .white)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .overlay(Capsule().stroke(active ? Brand.acid : .white.opacity(0.25), lineWidth: 1))
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .terminalRow()
            }

            Section(header: TerminalLabel(text: "полосы · дБ")) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(AudioProcessing.frequencies.indices, id: \.self) { band in
                        bandSlider(band)
                    }
                }
                .frame(height: 240)
                .opacity(state.eqEnabled ? 1 : 0.4)
                .terminalRow()
            }
        }
        .terminalPage()
        .navigationTitle("Эквалайзер")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bandSlider(_ band: Int) -> some View {
        let range = AudioProcessing.gainRange
        return VStack(spacing: 6) {
            Text(String(format: "%+.0f", state.gains[band]))
                .font(Brand.mono(10, weight: .bold))
                .foregroundStyle(state.gains[band] == 0 ? .white.opacity(0.5) : Brand.acid)
            GeometryReader { geo in
                Slider(
                    value: Binding(
                        get: { state.gains[band] },
                        set: { value in
                            let snapped = value.rounded()
                            if snapped != state.gains[band] { Haptics.tick() }
                            apply { $0.gains[band] = snapped; $0.eqEnabled = true }
                        }
                    ),
                    in: range
                )
                .tint(Brand.acid)
                .frame(width: geo.size.height)
                .rotationEffect(.degrees(-90))
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text(Self.label(AudioProcessing.frequencies[band]))
                .font(Brand.mono(9))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.label(AudioProcessing.frequencies[band])) герц")
        .accessibilityValue("\(Int(state.gains[band])) децибел")
        .accessibilityAdjustableAction { direction in
            let step: Float = direction == .increment ? 1 : -1
            apply { $0.gains[band] = min(max($0.gains[band] + step, range.lowerBound), range.upperBound) }
        }
    }

    private func apply(_ change: (inout AudioProcessing.State) -> Void) {
        AudioProcessing.shared.update(change)
        state = AudioProcessing.shared.snapshot()
    }

    private static func label(_ hz: Float) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}
