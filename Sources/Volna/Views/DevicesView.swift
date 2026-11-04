import SwiftUI

/// Other devices on the account (Ynison): what plays where, remote controls, and pulling
/// the track onto this phone at the same second.
struct DevicesView: View {
    @Environment(Session.self) private var session
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @State private var takingOver = false
    private var ynison: Ynison { Ynison.shared }

    var body: some View {
        List {
            TerminalHeader(title: "Устройства", caption: statusLine)
                .terminalRow()
                .listRowSeparator(.hidden)

            if let device = ynison.snapshot.activeDevice, let playing = ynison.snapshot.current {
                Section(header: TerminalLabel(text: "сейчас играет")) {
                    nowPlaying(device: device, playing: playing).terminalRow()
                }
            }

            Section(header: TerminalLabel(text: "в сети | \(ynison.snapshot.devices.count)")) {
                if ynison.snapshot.devices.isEmpty {
                    Text("> других устройств нет. Открой Яндекс Музыку на ПК или Станции.")
                        .font(Brand.mono(12))
                        .foregroundStyle(.white.opacity(0.5))
                        .terminalRow()
                }
                ForEach(ynison.snapshot.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: Self.symbol(for: device))
                            .font(.system(size: 20))
                            .foregroundStyle(device.id == ynison.snapshot.activeDeviceID ? Brand.acid : .white.opacity(0.7))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            Text(device.id == ynison.snapshot.activeDeviceID ? "> активно" : (device.isOffline ? "> не в сети" : "> в сети"))
                                .font(Brand.mono(11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .terminalRow()
                }
            }

            Section {
                Text("Волна подключается как пульт: видит и переключает музыку на других устройствах и умеет забрать её к себе. То, что играет на iPhone, другие устройства пока не видят.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .terminalRow()
            }
        }
        .terminalPage()
        .navigationTitle("Устройства")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusLine: String {
        switch ynison.status {
        case .idle: "ynison: offline"
        case .connecting: "ynison: connecting…"
        case .connected: "ynison: connected"
        case .failed(let reason): "ynison: \(reason.lowercased())"
        }
    }

    private func nowPlaying(device: Ynison.Device, playing: Ynison.Playable) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                CoverImage(uri: playing.coverURL, size: 300)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("> \(device.title.lowercased())").font(Brand.mono(11, weight: .bold)).foregroundStyle(Brand.acid)
                    Text(playing.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let snap = ynison.snapshot
                let total = max(snap.durationMs / 1000, 1)
                let now = snap.progress(at: context.date)
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.15)).frame(height: 2)
                            Rectangle().fill(Brand.acid).frame(width: geo.size.width * min(now / total, 1), height: 2)
                        }
                    }
                    .frame(height: 2)
                    HStack {
                        Text(Self.time(now))
                        Spacer()
                        Text(Self.time(total))
                    }
                    .font(Brand.mono(11))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack(spacing: 28) {
                Button { Haptics.step(); Task { await ynison.skip(-1) } } label: {
                    Image(systemName: "backward.end.fill")
                }
                .accessibilityLabel("Предыдущий трек на \(device.title)")
                Button {
                    Haptics.thump()
                    Task { await ynison.setPaused(!ynison.snapshot.paused) }
                } label: {
                    Image(systemName: ynison.snapshot.paused ? "play.fill" : "pause.fill")
                        .frame(width: 54, height: 54)
                        .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                }
                .accessibilityLabel(ynison.snapshot.paused ? "Играть на \(device.title)" : "Пауза на \(device.title)")
                Button { Haptics.step(); Task { await ynison.skip(1) } } label: {
                    Image(systemName: "forward.end.fill")
                }
                .accessibilityLabel("Следующий трек на \(device.title)")
            }
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                Task { await takeOver() }
            } label: {
                Label(takingOver ? "ЗАБИРАЮ…" : "ПОДХВАТИТЬ НА IPHONE", systemImage: "iphone.and.arrow.forward")
                    .font(Brand.mono(13, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Brand.ink)
                    .background(Brand.acid, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(takingOver)
        }
        .padding(.vertical, 6)
    }

    /// Plays the other device's queue here from the same track and second, then pauses it there.
    private func takeOver() async {
        guard let client = session.client else { return }
        let snap = ynison.snapshot
        guard snap.queue.indices.contains(snap.currentIndex) else { return }
        takingOver = true
        defer { takingOver = false }
        // Keep the load reasonable for long queues: a window around the current track.
        let start = max(0, snap.currentIndex - 20)
        let end = min(snap.queue.count, snap.currentIndex + 200)
        let refs = snap.queue[start..<end].map(\.ref)
        guard let tracks = try? await client.tracks(refs: Array(refs)), !tracks.isEmpty else { return }
        let currentID = snap.queue[snap.currentIndex].trackID
        let index = tracks.firstIndex { $0.id.value == currentID } ?? 0
        Haptics.launch()
        player.play(tracks, startAt: index, position: snap.progress())
        await ynison.setPaused(true)
        router.destination = nil
    }

    private static func symbol(for device: Ynison.Device) -> String {
        let type = device.type.uppercased()
        if type.contains("SMART_SPEAKER") || device.appName.lowercased().contains("station") { return "hifispeaker.fill" }
        if type.contains("ANDROID") || type.contains("IOS") || type.contains("PHONE") { return "iphone" }
        if type.contains("TV") { return "tv" }
        if type.contains("CAR") { return "car.fill" }
        return "desktopcomputer"
    }

    private static func time(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }
}
