import SwiftUI

/// Tuning My Wave on one screen, no scrolling: a radar web with one spoke per setting (mood,
/// character, language). Each option sits on its spoke; slide a finger along a spoke to pick,
/// the centre means "any". The picks are joined into an acid polygon, so the shape of the web
/// is the shape of your wave. Activity waves swipe along the bottom.
struct WaveSettingsView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @State private var settings: WaveSettings?
    /// Chosen option index per spoke key; nil or absent = centre ("любое").
    @State private var picks: [String: Int] = [:]
    @State private var error: String?

    private static let spokeTitles = ["moodEnergy": "настроение", "diversity": "характер", "language": "язык"]

    var body: some View {
        VStack(spacing: 14) {
            header
            if let settings {
                WaveWeb(spokes: spokes(settings), picks: $picks)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 8)
                activityStrip(settings)
            } else {
                Spacer()
                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    ProgressView().tint(Brand.acid)
                }
                Spacer()
            }
            launchButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Brand.ink)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("моя волна").font(Brand.display(17)).foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сбросить", systemImage: "arrow.counterclockwise") {
                    Haptics.tap()
                    withAnimation(.spring(duration: 0.4, bounce: 0.3)) { picks = [:] }
                }
                .disabled(picks.values.allSatisfy { $0 < 0 })
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("> веди пальцем по лучу. центр — без ограничений")
                .font(Brand.mono(11))
                .foregroundStyle(.white.opacity(0.45))
            Text(summary)
                .font(Brand.mono(14, weight: .bold))
                .foregroundStyle(Brand.acid)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: summary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var summary: String {
        guard let settings else { return " " }
        let parts = spokes(settings).compactMap { spoke -> String? in
            guard let index = picks[spoke.key], spoke.options.indices.contains(index) else { return nil }
            return spoke.options[index].name.lowercased()
        }
        return parts.isEmpty ? "обычная моя волна" : parts.joined(separator: " · ")
    }

    // MARK: Spokes

    private func spokes(_ settings: WaveSettings) -> [WaveWeb.Spoke] {
        let known = ["moodEnergy", "diversity", "language"]
        let rest = settings.settingRestrictions.keys.filter { !known.contains($0) }.sorted()
        return (known + rest).prefix(5).compactMap { key in
            let options = (settings.settingRestrictions[key]?.possibleValues ?? [])
                .filter { $0.unspecified != true && $0.serializedSeed != nil }
            guard !options.isEmpty else { return nil }
            return WaveWeb.Spoke(key: key, title: Self.spokeTitles[key] ?? key.lowercased(), options: options)
        }
    }

    // MARK: Activities

    private func activityStrip(_ settings: WaveSettings) -> some View {
        let stations = (settings.blocks ?? []).flatMap { $0.items ?? [] }
        return VStack(alignment: .leading, spacing: 8) {
            if !stations.isEmpty {
                Text("> или сразу волна под занятие →")
                    .font(Brand.mono(11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 4)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(stations, id: \.self) { station in
                            Button {
                                Haptics.launch()
                                player.startWave(seeds: [station.id.seed], title: station.name)
                                router.destination = nil
                            } label: {
                                Label(station.name.lowercased(), systemImage: Self.stationSymbol(station))
                                    .font(Brand.mono(12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .frame(height: 40)
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
            ("party", "party.popper"), ("вечерин", "party.popper"),
            ("relax", "cup.and.saucer"), ("отдых", "cup.and.saucer"),
            ("wake", "sunrise"), ("утр", "sunrise"),
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
                Preferences.waveSeeds = spokes(settings).compactMap { spoke in
                    picks[spoke.key].flatMap { spoke.options.indices.contains($0) ? spoke.options[$0].serializedSeed : nil }
                }
            }
            player.startWave()
            router.destination = nil
        } label: {
            Label("запустить", systemImage: "play.fill")
                .font(Brand.mono(15, weight: .heavy))
                .foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Brand.acid, in: .capsule)
                .shadow(color: Brand.acid.opacity(0.4), radius: 16)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let loaded = try await client.waveSettings()
            var saved: [String: Int] = [:]
            for spoke in spokes(loaded) {
                if let index = spoke.options.firstIndex(where: { Preferences.waveSeeds.contains($0.serializedSeed ?? "") }) {
                    saved[spoke.key] = index
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

/// The radar web itself: dotted rings and spokes, option labels on each spoke, and the acid
/// polygon through the current picks. Drag anywhere: the spoke nearest the finger's angle is
/// grabbed and the option nearest its distance from the centre is picked.
struct WaveWeb: View {
    struct Spoke: Hashable {
        let key: String
        let title: String
        let options: [WaveSettings.Option]
    }

    let spokes: [Spoke]
    @Binding var picks: [String: Int]
    /// The spoke held for the whole drag, so a finger that drifts doesn't jump spokes.
    @State private var grabbed: String?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Room for the labels outside the outermost ring.
            let radius = side / 2 - 34
            ZStack {
                Canvas { context, _ in
                    drawWeb(context, center: center, radius: radius)
                }
                ForEach(spokes, id: \.self) { spoke in
                    labels(for: spoke, center: center, radius: radius)
                }
                Text(anyPicked ? "·" : "∅ любое")
                    .font(Brand.mono(10, weight: .bold))
                    .foregroundStyle(anyPicked ? .white.opacity(0.4) : Brand.acid)
                    .position(x: center.x, y: center.y + 16)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in pick(at: value.location, center: center, radius: radius) }
                    .onEnded { _ in grabbed = nil }
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var anyPicked: Bool { picks.values.contains { $0 >= 0 } }

    private func angle(_ index: Int) -> Double {
        -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(spokes.count, 1))
    }

    /// Distance of option `i` (0-based) from the centre; the centre itself means "any".
    private func distance(_ i: Int, of count: Int, radius: CGFloat) -> CGFloat {
        radius * CGFloat(i + 1) / CGFloat(count)
    }

    private func point(_ spokeIndex: Int, _ r: CGFloat, center: CGPoint) -> CGPoint {
        let a = angle(spokeIndex)
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    private func pickedPoint(_ index: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let spoke = spokes[index]
        guard let i = picks[spoke.key], spoke.options.indices.contains(i) else { return center }
        return point(index, distance(i, of: spoke.options.count, radius: radius), center: center)
    }

    private func drawWeb(_ context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let dotted = StrokeStyle(lineWidth: 1, dash: [2, 5])
        // Rings.
        for step in 1...4 {
            let r = radius * CGFloat(step) / 4
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                           with: .color(.white.opacity(0.12)), style: dotted)
        }
        // Spokes and option nodes.
        for (index, spoke) in spokes.enumerated() {
            var line = Path()
            line.move(to: center)
            line.addLine(to: point(index, radius, center: center))
            context.stroke(line, with: .color(.white.opacity(0.22)), style: dotted)
            for i in spoke.options.indices {
                let p = point(index, distance(i, of: spoke.options.count, radius: radius), center: center)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                             with: .color(.white.opacity(0.45)))
            }
        }
        // The picks as one shape.
        guard !spokes.isEmpty else { return }
        var shape = Path()
        for index in spokes.indices {
            let p = pickedPoint(index, center: center, radius: radius)
            if index == 0 { shape.move(to: p) } else { shape.addLine(to: p) }
        }
        shape.closeSubpath()
        context.fill(shape, with: .color(Brand.acid.opacity(0.16)))
        context.stroke(shape, with: .color(Brand.acid), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        for index in spokes.indices {
            let p = pickedPoint(index, center: center, radius: radius)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Brand.acid))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Brand.ink))
        }
        context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                     with: .color(.white.opacity(0.6)))
    }

    private func labels(for spoke: Spoke, center: CGPoint, radius: CGFloat) -> some View {
        let index = spokes.firstIndex(of: spoke) ?? 0
        let a = angle(index)
        // Labels sit beside their node, pushed off the spoke so they don't cover it.
        let normal = CGPoint(x: -sin(a), y: cos(a))
        let side: CGFloat = cos(a) < -0.1 ? -1 : 1
        return ZStack {
            ForEach(Array(spoke.options.enumerated()), id: \.offset) { i, option in
                let selected = picks[spoke.key] == i
                let p = point(index, distance(i, of: spoke.options.count, radius: radius), center: center)
                Text(option.name.lowercased())
                    .font(Brand.mono(selected ? 12 : 10, weight: selected ? .heavy : .medium))
                    .foregroundStyle(selected ? Brand.acid : .white.opacity(0.6))
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .background(selected ? Brand.ink.opacity(0.85) : .clear, in: .rect(cornerRadius: 3))
                    .position(x: p.x + normal.x * 16 * side, y: p.y + normal.y * 16 * side)
                    .animation(.snappy, value: selected)
            }
            Text(spoke.title.uppercased())
                .font(Brand.display(15))
                .foregroundStyle(.white)
                .fixedSize()
                .position(point(index, radius + 22, center: center))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoke.title)
        .accessibilityValue(picks[spoke.key].flatMap { spoke.options.indices.contains($0) ? spoke.options[$0].name : nil } ?? "любое")
        .accessibilityAdjustableAction { direction in
            let current = picks[spoke.key] ?? -1
            let next = direction == .increment ? min(current + 1, spoke.options.count - 1) : max(current - 1, -1)
            picks[spoke.key] = next
        }
    }

    private func pick(at location: CGPoint, center: CGPoint, radius: CGFloat) {
        let dx = location.x - center.x, dy = location.y - center.y
        let r = hypot(dx, dy)
        // Grab the spoke whose direction is closest to the finger, once per drag.
        if grabbed == nil {
            guard r > 14 else { return }
            let a = atan2(dy, dx)
            let nearest = spokes.indices.min { lhs, rhs in
                angularGap(a, angle(lhs)) < angularGap(a, angle(rhs))
            }
            grabbed = nearest.map { spokes[$0].key }
        }
        guard let key = grabbed, let index = spokes.firstIndex(where: { $0.key == key }) else { return }
        let spoke = spokes[index]
        // Project onto the spoke, then snap to the nearest option (or the centre).
        let a = angle(index)
        let along = max(0, dx * cos(a) + dy * sin(a))
        let step = radius / CGFloat(spoke.options.count)
        let slot = Int((along / step).rounded()) - 1
        let pickIndex = min(max(slot, -1), spoke.options.count - 1)
        if (picks[key] ?? -1) != pickIndex {
            pickIndex < 0 ? Haptics.step() : Haptics.tick()
            withAnimation(.spring(duration: 0.3, bounce: 0.35)) { picks[key] = pickIndex }
        }
    }

    private func angularGap(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        return min(d, 2 * .pi - d)
    }
}
