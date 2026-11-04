import SwiftUI
import UIKit

/// «Режим покоя»: everything but the music steps away. The visualizer fills the screen, the
/// status bar and home indicator hide, the controls shrink to three thin glyphs, and the clock
/// and battery move to the bottom where the tab bar was. The screen stays on; it isn't a lock.
struct IdleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var player
    @AppStorage("tunnelASCII") private var ascii = true
    @AppStorage(VisualizerEffect.storageKey) private var effectRaw = VisualizerEffect.relief.rawValue
    /// The close button shows for a moment after a tap, then fades again.
    @State private var showClose = false
    @State private var closeTask: Task<Void, Never>?
    @State private var pull: CGFloat = 0
    @State private var battery: Float = UIDevice.current.batteryLevel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CoverVisualizer(coverURI: player.current?.cover, ascii: ascii, isPlaying: player.isPlaying,
                            accent: Theme.shared.accentRGB,
                            effect: VisualizerEffect(rawValue: effectRaw) ?? .relief,
                            palette: Theme.shared.smokePalette)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                nowPlaying
                Spacer()
                clock
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 28)

            if showClose {
                Button { Haptics.tap(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).padding(12)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 8)
                .padding(.trailing, 16)
                .transition(.opacity)
            }
        }
        .offset(y: max(0, pull))
        .contentShape(.rect)
        .onTapGesture { flashClose() }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { pull = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 140 { Haptics.tap(); dismiss() }
                    withAnimation(.spring) { pull = 0 }
                }
        )
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            battery = UIDevice.current.batteryLevel
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            battery = UIDevice.current.batteryLevel
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 14) {
            Text(player.current?.artists.first?.name ?? "волна")
                .font(Brand.display(44))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .shadow(color: .black.opacity(0.6), radius: 18)
            Text((player.current?.fullTitle ?? "").lowercased())
                .font(Brand.mono(15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            HStack(spacing: 44) {
                glyphButton(.previous, height: 16) { player.previous() }
                glyphButton(player.isPlaying ? .pause : .play, height: 22) { player.togglePlay() }
                glyphButton(.next, height: 16) { player.next() }
            }
            .padding(.top, 10)
        }
    }

    private func glyphButton(_ kind: TransportGlyph.Kind, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.step(); action()
        } label: {
            TransportGlyph.icon(kind, height: height)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 54, height: 54)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Time, date and battery where the tab bar usually is.
    private var clock: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 4) {
                Text(context.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(Brand.display(54))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                HStack(spacing: 12) {
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU"))).lowercased())
                    if battery >= 0 {
                        Text("|")
                        Label("\(Int((battery * 100).rounded()))%", systemImage: Self.batterySymbol(battery))
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(Brand.mono(12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private static func batterySymbol(_ level: Float) -> String {
        switch level {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func flashClose() {
        closeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showClose = true }
        closeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showClose = false }
        }
    }
}
