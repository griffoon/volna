import AppIntents
import SwiftUI
import WidgetKit

@main
struct VolnaWidgets: WidgetBundle {
    var body: some Widget {
        VolnaWidget()
        VolnaWaveControl()
    }
}

private enum Links {
    static let wave = URL(string: "volna://wave")!
    static let liked = URL(string: "volna://liked")!
    static let toggle = URL(string: "volna://toggle")!
}

// MARK: - Home & Lock Screen widget

struct VolnaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VolnaWidget", provider: Provider()) { _ in
            WidgetView()
        }
        .configurationDisplayName("Волна")
        .description("Моя волна и любимое в одно касание.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }

    struct Entry: TimelineEntry {
        let date = Date()
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry() }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry())
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry()], policy: .never))
        }
    }
}

private struct WidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform").font(.title2.weight(.semibold))
            }
            .widgetURL(Links.wave)
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            HStack {
                Image(systemName: "waveform").font(.title2)
                VStack(alignment: .leading) {
                    Text("Моя волна").font(.headline)
                    Text("Нажми и слушай").font(.caption)
                }
            }
            .widgetURL(Links.wave)
            .containerBackground(.clear, for: .widget)
        case .systemMedium:
            HStack(spacing: 12) {
                tile(Links.wave, "Моя волна", "waveform", tint: .orange)
                tile(Links.liked, "Мне нравится", "heart.fill", tint: .pink)
            }
            .containerBackground(for: .widget) { background }
        default:
            VStack(alignment: .leading) {
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Моя волна").font(.headline).foregroundStyle(.white)
                Text("Нажми и слушай").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(Links.wave)
            .containerBackground(for: .widget) { background }
        }
    }

    private func tile(_ url: URL, _ title: String, _ symbol: String, tint: Color) -> some View {
        Link(destination: url) {
            VStack(alignment: .leading) {
                Image(systemName: symbol).font(.title.weight(.bold))
                Spacer()
                Text(title).font(.headline)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(tint.opacity(0.35).gradient, in: .rect(cornerRadius: 16, style: .continuous))
        }
    }

    private var background: some View {
        LinearGradient(colors: [.black, .indigo, .orange.opacity(0.85)], startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }
}

// MARK: - Control Center / Action Button

struct VolnaWaveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "VolnaWaveControl") {
            ControlWidgetButton(action: OpenURLIntent(Links.toggle)) {
                Label("Моя волна", systemImage: "waveform")
            }
        }
        .displayName("Моя волна")
        .description("Запустить или поставить на паузу.")
    }
}
