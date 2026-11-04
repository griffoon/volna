import CoreMotion
import SwiftUI

/// «Посмотреть диск»: the release as a physical CD. Pull the lid of the jewel case open, pull the
/// disc up out of the tray, then spin it with a finger; tilting the phone moves a matte rainbow
/// sheen across the printed cover, the way light plays on a real disc.
struct DiscViewer: View {
    @Environment(\.dismiss) private var dismiss
    let cover: String?
    let title: String
    let artist: String

    private enum Stage { case closed, open, out }

    @State private var stage: Stage = .closed
    /// Lid angle while opening, 0 (shut) … 165 (open).
    @State private var lid: Double = 0
    /// Disc lift out of the tray while dragging it up.
    @State private var lift: CGFloat = 0
    @State private var spin: Double = 0
    @State private var spinAtDragStart: Double?
    @State private var lastTickAngle: Double = 0
    @State private var motion = MotionTilt()

    private static let caseSide: CGFloat = 280
    private static let openAngle: Double = 165

    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            RadialGradient(colors: [Brand.acid.opacity(0.12), .clear], center: .center, startRadius: 20, endRadius: 360)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(Brand.display(24))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(artist.lowercased())
                        .font(Brand.mono(13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 30)
                Spacer()
                stageView
                Spacer()
                Text(hint)
                    .font(Brand.mono(13, weight: .bold))
                    .foregroundStyle(Brand.acid)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: hint)
                    .padding(.bottom, 26)
            }
            .padding(.horizontal, 20)

            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).padding(12)
            }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    private var hint: String {
        switch stage {
        case .closed: "← потяни крышку, чтобы открыть"
        case .open: "↑ потяни диск вверх, чтобы достать"
        case .out: "↻ крути диск пальцем, наклоняй телефон"
        }
    }

    @ViewBuilder
    private var stageView: some View {
        switch stage {
        case .closed, .open: jewelCase
        case .out: looseDisc.transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    // MARK: Case

    private var jewelCase: some View {
        let side = Self.caseSide
        return ZStack {
            // Tray: dark plastic with the spindle, the disc sitting on it.
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.09))
                RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.25), lineWidth: 1)
                SheenDisc(cover: cover, size: side * 0.9, tilt: motion.tilt, spin: 0)
                    .offset(y: -lift)
                    .gesture(stage == .open ? liftGesture : nil)
            }
            .frame(width: side, height: side)

            // Lid: the clear front with the insert behind it, hinged on the left.
            lidView
                .rotation3DEffect(.degrees(-lid), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.45)
                .allowsHitTesting(stage == .closed)
                .gesture(stage == .closed ? lidGesture : nil)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.8), radius: 30, y: 18)
    }

    private var lidView: some View {
        let side = Self.caseSide
        return ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.05))
            CoverImage(uri: cover, size: 800, corner: 0)
                .frame(width: side - 22, height: side - 12)
                .offset(x: 18)
            VStack(spacing: 6) {
                ForEach(0..<28, id: \.self) { _ in
                    Rectangle().fill(.white.opacity(0.22)).frame(width: 6, height: 1)
                }
            }
            .frame(width: 14, height: side)
            .background(.white.opacity(0.1))
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .white.opacity(0.26), location: 0.35),
                .init(color: .white.opacity(0.03), location: 0.5), .init(color: .clear, location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: side, height: side)
        .overlay(Rectangle().stroke(.white.opacity(0.5), lineWidth: 1))
        .contentShape(.rect)
    }

    private var lidGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let next = min(max(-value.translation.width / Self.caseSide * 180, 0), Self.openAngle)
                if Int(next / 30) != Int(lid / 30) { Haptics.tick() }
                lid = next
            }
            .onEnded { value in
                if lid > 70 || value.predictedEndTranslation.width < -Self.caseSide * 0.6 {
                    Haptics.thump()
                    withAnimation(.spring(duration: 0.5, bounce: 0.25)) { lid = Self.openAngle; stage = .open }
                } else {
                    withAnimation(.spring(duration: 0.4, bounce: 0.3)) { lid = 0 }
                }
            }
    }

    private var liftGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in lift = max(0, -value.translation.height) }
            .onEnded { value in
                if lift > 110 || value.predictedEndTranslation.height < -260 {
                    Haptics.launch()
                    withAnimation(.spring(duration: 0.55, bounce: 0.3)) { stage = .out }
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { lift = 0 }
                }
            }
    }

    // MARK: Loose disc

    private var looseDisc: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            SheenDisc(cover: cover, size: min(geo.size.width, 330), tilt: motion.tilt, spin: spin)
                .position(center)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Turn by the angle the finger sweeps around the centre.
                            let start = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
                            let now = atan2(value.location.y - center.y, value.location.x - center.x)
                            if spinAtDragStart == nil { spinAtDragStart = spin }
                            spin = (spinAtDragStart ?? 0) + (now - start) * 180 / .pi
                            if abs(spin - lastTickAngle) > 30 { Haptics.tick(); lastTickAngle = spin }
                        }
                        .onEnded { value in
                            // A flick keeps it turning and slowing down.
                            let start = atan2(value.location.y - center.y, value.location.x - center.x)
                            let end = atan2(value.predictedEndLocation.y - center.y, value.predictedEndLocation.x - center.x)
                            var delta = (end - start) * 180 / .pi
                            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                            spinAtDragStart = nil
                            withAnimation(.easeOut(duration: 1.6)) { spin += delta * 3 }
                        }
                )
        }
        .frame(height: 340)
    }
}

/// A printed CD whose sheen follows how the phone is tilted: a matte rainbow band slides over the
/// cover and the silver rim catches a highlight.
private struct SheenDisc: View {
    let cover: String?
    let size: CGFloat
    let tilt: CGSize
    let spin: Double

    var body: some View {
        ZStack {
            CDDisc(size: size, cover: cover)
                .rotationEffect(.degrees(spin))
            // Rainbow interference, turning with the tilt rather than with the disc.
            Circle()
                .fill(AngularGradient(colors: [
                    .clear, Color(red: 0.6, green: 0.85, blue: 1).opacity(0.35), .clear,
                    Color(red: 1, green: 0.7, blue: 0.9).opacity(0.3), .clear,
                    Color(red: 0.8, green: 1, blue: 0.6).opacity(0.3), .clear,
                ], center: .center, angle: .degrees(Double(tilt.width) * 160)))
                .blendMode(.screen)
            // A soft matte highlight that slides with the tilt.
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(
                    x: 0.5 + tilt.width * 0.6, y: 0.5 + tilt.height * 0.6), startRadius: 0, endRadius: size * 0.55))
                .blendMode(.softLight)
            // Keep the hole see-through under the overlays.
            Circle().fill(Brand.ink).frame(width: size * 0.12, height: size * 0.12)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.6), radius: 20, y: 12)
    }
}

/// Phone tilt from the motion sensors, smoothed, as -1…1 on each axis.
@MainActor
@Observable
final class MotionTilt {
    private(set) var tilt: CGSize = .zero
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }
            let target = CGSize(width: max(-1, min(1, attitude.roll / 0.8)),
                                height: max(-1, min(1, (attitude.pitch - 0.7) / 0.8)))
            self.tilt = CGSize(width: self.tilt.width + (target.width - self.tilt.width) * 0.2,
                               height: self.tilt.height + (target.height - self.tilt.height) * 0.2)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}
