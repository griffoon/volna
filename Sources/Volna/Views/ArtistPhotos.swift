import SwiftUI

/// The artist's photos as the page header: swipe between them, dots show how many there are,
/// a tap opens them full screen.
struct ArtistPhotoPager: View {
    let photos: [String]
    @Binding var page: Int
    let open: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if photos.isEmpty {
                Rectangle().fill(.white.opacity(0.04))
            } else {
                TabView(selection: $page) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, uri in
                        CoverImage(uri: uri, size: 800, corner: 0)
                            .grayscale(0.4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .contentShape(.rect)
                            .onTapGesture { Haptics.tap(); open() }
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: page) { Haptics.tick() }
            }
            LinearGradient(colors: [.clear, Brand.ink], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            if photos.count > 1 {
                PageDots(count: photos.count, current: page)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Фото исполнителя \(page + 1) из \(max(photos.count, 1))")
        .accessibilityAction(named: "Открыть фото", open)
    }
}

/// Small terminal-style page dots: the current one is a wide acid bar.
struct PageDots: View {
    let count: Int
    let current: Int
    /// Past this many, only a window around the current page is drawn.
    private static let maxVisible = 9

    var body: some View {
        let range = visibleRange
        HStack(spacing: 5) {
            ForEach(range, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Brand.acid : .white.opacity(0.45))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: .capsule)
        .animation(.snappy, value: current)
    }

    private var visibleRange: [Int] {
        guard count > Self.maxVisible else { return Array(0..<count) }
        let start = min(max(current - Self.maxVisible / 2, 0), count - Self.maxVisible)
        return Array(start..<(start + Self.maxVisible))
    }
}

/// Full-screen photos in colour, swipe between them, pinch to zoom, swipe down or ✕ to close.
struct ArtistPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [String]
    @Binding var page: Int
    @State private var zoom: CGFloat = 1
    @State private var pull: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(abs(pull) / 400, 0.6))
            TabView(selection: $page) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, uri in
                    CoverImage(uri: uri, size: 1000, corner: 0)
                        .scaledToFit()
                        .scaleEffect(index == page ? zoom : 1)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: pull)
            .gesture(
                MagnifyGesture()
                    .onChanged { zoom = min(max($0.magnification, 1), 4) }
                    .onEnded { _ in withAnimation(.spring) { zoom = 1 } }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard zoom == 1, abs(value.translation.height) > abs(value.translation.width) else { return }
                        pull = value.translation.height
                    }
                    .onEnded { value in
                        if abs(value.translation.height) > 140 { Haptics.tap(); dismiss() }
                        withAnimation(.spring) { pull = 0 }
                    }
            )
            .onChange(of: page) { Haptics.tick(); zoom = 1 }

            VStack {
                Spacer()
                if photos.count > 1 {
                    PageDots(count: photos.count, current: page).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)

            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).padding(12)
            }
            .buttonStyle(.glass)
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}
