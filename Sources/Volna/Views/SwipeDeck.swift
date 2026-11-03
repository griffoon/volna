import SwiftUI

/// The cover as a card: it follows the finger with a slight tilt, the neighbouring cover slides
/// in from the side so you can peek at what's next, and letting go past the threshold switches.
struct CoverDeck: View {
    @Environment(PlayerEngine.self) private var player
    @State private var drag: CGFloat = 0

    private static let gap: CGFloat = 28
    /// Share of the width (or flick speed) that commits a switch.
    private static let threshold: CGFloat = 0.28

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let progress = min(abs(drag) / w, 1)
            ZStack {
                if drag < 0, let next = player.nextTrack {
                    card(next, label: "далее")
                        .offset(x: drag + w + Self.gap)
                        .scaleEffect(0.9 + 0.1 * progress)
                }
                if drag > 0, let previous = player.previousTrack {
                    card(previous, label: "назад")
                        .offset(x: drag - w - Self.gap)
                        .scaleEffect(0.9 + 0.1 * progress)
                }
                if let current = player.current {
                    card(current, label: nil)
                        .offset(x: drag)
                        .rotationEffect(.degrees(Double(drag / w) * 7), anchor: .bottom)
                        .scaleEffect(player.isPlaying ? 1 - 0.06 * progress : 0.9)
                        .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
                }
            }
            .frame(width: w, height: w)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        // Resist when there is nothing on that side.
                        let x = value.translation.width
                        let blocked = (x < 0 && player.nextTrack == nil && !player.isWave) || (x > 0 && player.previousTrack == nil)
                        drag = blocked ? x * 0.25 : x
                    }
                    .onEnded { value in
                        let flick = value.predictedEndTranslation.width
                        if (drag < -w * Self.threshold || flick < -w * 0.6), player.nextTrack != nil || player.isWave {
                            commit(to: -(w + Self.gap)) { player.next() }
                        } else if (drag > w * Self.threshold || flick > w * 0.6), player.previousTrack != nil {
                            commit(to: w + Self.gap) { player.goBack() }
                        } else {
                            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { drag = 0 }
                        }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .sensoryFeedback(.selection, trigger: player.current?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(player.current.map { "Обложка: \($0.fullTitle)" } ?? "Обложка")
        .accessibilityHint("Свайп влево — следующий трек, вправо — предыдущий")
        .accessibilityAction(named: "Следующий трек") { player.next() }
        .accessibilityAction(named: "Предыдущий трек") { player.goBack() }
    }

    private func commit(to target: CGFloat, action: @escaping () -> Void) {
        withAnimation(.spring(duration: 0.28, bounce: 0)) {
            drag = target
        } completion: {
            action()
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { drag = 0 }
        }
    }

    private func card(_ track: Track, label: String?) -> some View {
        CoverImage(uri: track.cover, size: 800, corner: 2)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.15), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if let label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("> \(label)").foregroundStyle(Brand.acid)
                        Text(track.fullTitle).foregroundStyle(.white).lineLimit(1)
                    }
                    .font(Brand.mono(12, weight: .bold))
                    .padding(8)
                    .background(.black.opacity(0.8))
                    .padding(10)
                }
            }
            .shadow(color: .black, radius: 40)
    }
}

/// Horizontal swipe for the mini player: content slides with the finger, the next or previous
/// title peeks in, and a swipe past the threshold switches tracks.
struct MiniPlayerSwipe: ViewModifier {
    @Environment(PlayerEngine.self) private var player
    @State private var drag: CGFloat = 0

    private static let commitDistance: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .offset(x: drag)
            .opacity(1 - min(abs(drag) / 220, 0.6))
            .background {
                peek
                    .opacity(min(abs(drag) / Self.commitDistance, 1))
            }
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height), player.current != nil else { return }
                        drag = value.translation.width
                    }
                    .onEnded { value in
                        let x = value.translation.width
                        if x < -Self.commitDistance, player.nextTrack != nil || player.isWave {
                            player.next()
                        } else if x > Self.commitDistance, player.previousTrack != nil {
                            player.goBack()
                        }
                        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { drag = 0 }
                    }
            )
            .sensoryFeedback(.selection, trigger: player.current?.id)
    }

    @ViewBuilder
    private var peek: some View {
        let target = drag < 0 ? player.nextTrack : player.previousTrack
        HStack {
            if drag > 0 {
                Text("‹ \(target?.fullTitle ?? "—")")
                Spacer()
            } else {
                Spacer()
                Text("\(target?.fullTitle ?? (player.isWave ? "дальше по волне" : "—")) ›")
            }
        }
        .font(Brand.mono(12, weight: .bold))
        .foregroundStyle(Brand.acid)
        .lineLimit(1)
        .padding(.horizontal, 16)
    }
}
