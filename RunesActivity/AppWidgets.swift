import AppIntents
import SwiftUI
import WidgetKit

// Home Screen widgets that open a Runes app: a small one for one app and a medium one
// for up to four, each chosen when the widget is edited. A tap opens `runes://app/<id>`,
// which `RootView` turns into that app's screen.

extension AppLink: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let caseDisplayRepresentations: [AppLink: DisplayRepresentation] = [
        .workouts: "Workouts",
        .score: "Score",
        .cook: "Cook",
        .capture: "Capture",
    ]
}

// MARK: Configuration

struct OneAppIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Runes app"
    static let description = IntentDescription("Opens one of your Runes apps.")

    @Parameter(title: "App", default: .workouts)
    var app: AppLink

    init() {}
    init(app: AppLink) { self.app = app }
}

struct FourAppsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Runes apps"
    static let description = IntentDescription("Opens up to four of your Runes apps.")

    @Parameter(title: "First", default: .workouts) var first: AppLink?
    @Parameter(title: "Second", default: .score) var second: AppLink?
    @Parameter(title: "Third", default: .cook) var third: AppLink?
    @Parameter(title: "Fourth", default: .capture) var fourth: AppLink?

    init() {}
    init(_ apps: [AppLink?]) {
        first = apps.count > 0 ? apps[0] : nil
        second = apps.count > 1 ? apps[1] : nil
        third = apps.count > 2 ? apps[2] : nil
        fourth = apps.count > 3 ? apps[3] : nil
    }

    /// The chosen apps in order, each once; empty slots are skipped.
    var apps: [AppLink] {
        var seen: [AppLink] = []
        for app in [first, second, third, fourth].compactMap({ $0 }) where !seen.contains(app) { seen.append(app) }
        return seen
    }
}

// MARK: Timelines

struct AppsEntry: TimelineEntry {
    let date: Date
    let apps: [AppLink]
}

/// The widgets show no live state, so each needs one entry, kept until it is edited.
struct OneAppProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AppsEntry { AppsEntry(date: .now, apps: [.workouts]) }
    func snapshot(for configuration: OneAppIntent, in context: Context) async -> AppsEntry {
        AppsEntry(date: .now, apps: [configuration.app])
    }
    func timeline(for configuration: OneAppIntent, in context: Context) async -> Timeline<AppsEntry> {
        Timeline(entries: [AppsEntry(date: .now, apps: [configuration.app])], policy: .never)
    }
}

struct FourAppsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AppsEntry { AppsEntry(date: .now, apps: AppLink.allCases) }
    func snapshot(for configuration: FourAppsIntent, in context: Context) async -> AppsEntry {
        AppsEntry(date: .now, apps: configuration.apps)
    }
    func timeline(for configuration: FourAppsIntent, in context: Context) async -> Timeline<AppsEntry> {
        Timeline(entries: [AppsEntry(date: .now, apps: configuration.apps)], policy: .never)
    }
}

// MARK: Widgets

struct OneAppWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.runes.widget.app", intent: OneAppIntent.self, provider: OneAppProvider()) { entry in
            OneAppView(app: entry.apps.first ?? .workouts)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Runes app")
        .description("Opens one Runes app. Touch and hold the widget to choose which.")
        .supportedFamilies([.systemSmall])
    }
}

struct FourAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.runes.widget.apps", intent: FourAppsIntent.self, provider: FourAppsProvider()) { entry in
            FourAppsView(apps: entry.apps)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Runes apps")
        .description("Opens up to four Runes apps. Touch and hold the widget to choose them.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: Views

/// An app's Lucide icon, stroked like the app draws it.
private struct AppGlyph: View {
    let app: AppLink
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width, geo.size.height) / 24
            let path = app.paths.reduce(into: Path()) { $0.addPath(SVGPath.cached($1)) }
            path.applying(CGAffineTransform(scaleX: k, y: k))
                .stroke(style: StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The icon in a hairline circle, as in the Applications list.
private struct AppBadge: View {
    let app: AppLink
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            AppGlyph(app: app).frame(width: size * 0.42, height: size * 0.42).widgetAccentable()
        }
        .frame(width: size, height: size)
    }
}

struct OneAppView: View {
    let app: AppLink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppBadge(app: app, size: 48)
            Spacer(minLength: 8)
            Text(app.title).font(.headline).lineLimit(1)
            Text("Runes").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(app.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(app.title)")
    }
}

struct FourAppsView: View {
    let apps: [AppLink]

    var body: some View {
        if apps.isEmpty {
            Text("Touch and hold to choose apps")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 8) {
                ForEach(apps, id: \.self) { app in
                    Link(destination: app.url) { tile(app) }
                        .accessibilityLabel("Open \(app.title)")
                }
            }
        }
    }

    private func tile(_ app: AppLink) -> some View {
        VStack(spacing: 10) {
            AppBadge(app: app, size: 44)
            Text(app.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}

#Preview("One app", as: .systemSmall) {
    OneAppWidget()
} timeline: {
    AppsEntry(date: .now, apps: [.cook])
}

#Preview("Four apps", as: .systemMedium) {
    FourAppsWidget()
} timeline: {
    AppsEntry(date: .now, apps: AppLink.allCases)
    AppsEntry(date: .now, apps: [.score, .capture])
}
