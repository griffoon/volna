import SwiftUI

/// «Карточка трека»: a poster of what's playing in the app's own style (cover, artist in Dela,
/// and the spectrum frozen at the moment you pressed it), rendered to an image you can share
/// to stories or chats.
struct ShareCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.6), radius: 30)
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(track.fullTitle, image: Image(uiImage: image))) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                            .font(Brand.mono(15, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.acid)
                } else {
                    ProgressView().tint(.white).frame(maxHeight: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.ink)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .task { await render() }
    }

    private func render() async {
        let spectrum = AudioAnalyzer.shared.snapshot().spectrum
        let bpm = AudioAnalyzer.shared.tempo()
        var cover: UIImage?
        if let url = CoverURL.make(track.cover, size: 1000),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            cover = UIImage(data: data)
        }
        let poster = ShareCardPoster(track: track, cover: cover, spectrum: spectrum, bpm: bpm, accent: Brand.acid)
        let renderer = ImageRenderer(content: poster)
        renderer.scale = 1
        image = renderer.uiImage
        Haptics.success()
    }
}

/// The poster itself, laid out at 1080×1350 (4:5, fits feeds and stories).
private struct ShareCardPoster: View {
    let track: Track
    let cover: UIImage?
    let spectrum: [Float]
    let bpm: Double?
    let accent: Color

    private static let blocks = Array(" ▁▂▃▄▅▆▇█")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("> volna · now playing")
                Spacer()
                if let bpm { Text("\(Int(bpm.rounded())) bpm") }
            }
            .font(.system(size: 30, weight: .bold, design: .monospaced))
            .foregroundStyle(accent)
            .padding(.bottom, 44)

            Group {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.white.opacity(0.06))
                }
            }
            .frame(width: 600, height: 600)
            .clipped()
            .overlay(Rectangle().stroke(.white.opacity(0.2), lineWidth: 2))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 56)

            Text(track.artistLine)
                .font(Brand.display(84))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
            Text(track.fullTitle.lowercased())
                .font(.system(size: 38, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .padding(.top, 10)

            Spacer(minLength: 0)

            Text(bars)
                .font(.system(size: 40, design: .monospaced))
                .foregroundStyle(accent.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(64)
        .frame(width: 1080, height: 1350)
        .background(Color(red: 0.02, green: 0.02, blue: 0.024))
    }

    /// The spectrum at the moment of sharing as block characters; a calm line when silent.
    private var bars: String {
        let top = Self.blocks.count - 1
        let values = spectrum.contains { $0 > 0.02 } ? spectrum : spectrum.indices.map { _ in Float(0.12) }
        return String(values.map { Self.blocks[min(top, max(1, Int(($0 * Float(top)).rounded())))] })
    }
}
