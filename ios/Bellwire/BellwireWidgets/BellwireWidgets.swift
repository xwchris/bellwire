// SPDX-License-Identifier: MPL-2.0
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BellwireWidgetBundle: WidgetBundle {
    var body: some Widget {
        BellwireSurfacesWidget()
        BellwireSurfaceLiveActivity()
    }
}

private struct BellwireTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: BellwireWidgetSnapshot
}

private struct BellwireTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BellwireTimelineEntry {
        .init(date: .now, snapshot: Self.preview)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (BellwireTimelineEntry) -> Void
    ) {
        completion(.init(date: .now, snapshot: readSnapshot() ?? Self.preview))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<BellwireTimelineEntry>) -> Void
    ) {
        let snapshot = readSnapshot()
            ?? BellwireWidgetSnapshot(isPro: false, updatedAt: .now, surfaces: [])
        completion(
            Timeline(
                entries: [.init(date: .now, snapshot: snapshot)],
                policy: .after(Date().addingTimeInterval(15 * 60))
            )
        )
    }

    private func readSnapshot() -> BellwireWidgetSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ),
        let data = try? Data(
            contentsOf: container.appendingPathComponent("bellwire-widget-snapshot.json")
        )
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BellwireWidgetSnapshot.self, from: data)
    }

    private var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "BellwireAppGroup") as? String
            ?? "group.app.bellwire.shared"
    }

    private static let preview = BellwireWidgetSnapshot(
        isPro: true,
        updatedAt: .now,
        surfaces: [
            .init(
                id: "preview",
                projectID: "preview-project",
                projectName: "VideoSays",
                projectIcon: "play.rectangle.fill",
                title: "Today revenue",
                subtitle: "47 orders",
                value: "$3,842",
                progress: nil,
                updatedAt: .now
            )
        ]
    )
}

private struct BellwireSurfacesWidget: Widget {
    let kind = "BellwireSurfaces"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BellwireTimelineProvider()) { entry in
            BellwireWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.055, green: 0.052, blue: 0.046)
                }
        }
        .configurationDisplayName("Bellwire Surfaces")
        .description("Keep your most important project state on the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct BellwireWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BellwireTimelineEntry

    var body: some View {
        if !entry.snapshot.isPro {
            VStack(alignment: .leading, spacing: 8) {
                Label("Bellwire Pro", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(accent)
                Text("Unlock live project Surfaces on your Home Screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(widgetURL("home"))
        } else if entry.snapshot.surfaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Bellwire", systemImage: "bell.fill")
                    .font(.headline)
                    .foregroundStyle(accent)
                Text("Publish a Surface to see live project state here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
                ForEach(entry.snapshot.surfaces.prefix(family == .systemSmall ? 1 : 2)) { surface in
                    surfaceRow(surface)
                    if surface.id != entry.snapshot.surfaces.prefix(2).last?.id,
                       family == .systemMedium {
                        Divider().overlay(Color.white.opacity(0.1))
                    }
                }
                Spacer(minLength: 0)
                Text(entry.snapshot.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .widgetURL(widgetURL("home"))
        }
    }

    private func surfaceRow(_ surface: BellwireNativeSurface) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: surface.projectIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text(surface.projectName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let value = surface.value {
                    Text(value)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
            }
            Text(surface.title)
                .font(.headline)
                .lineLimit(1)
            if let progress = surface.progress {
                ProgressView(value: progress)
                    .tint(accent)
            } else if let subtitle = surface.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var accent: Color {
        Color(red: 1.0, green: 0.58, blue: 0.08)
    }

    private func widgetURL(_ host: String) -> URL? {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "BellwireURLScheme") as? String
            ?? "bellwire"
        return URL(string: "\(scheme)://\(host)")
    }
}

private struct BellwireSurfaceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BellwireActivityAttributes.self) { context in
            BellwireLiveActivityLockScreen(context: context)
                .activityBackgroundTint(Color(red: 0.055, green: 0.052, blue: 0.046))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.projectIcon)
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let value = context.state.value {
                        Text(value)
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        if let progress = context.state.progress {
                            ProgressView(value: progress).tint(accent)
                        } else if let subtitle = context.state.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.projectIcon)
                    .foregroundStyle(accent)
            } compactTrailing: {
                if let progress = context.state.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2)
                        .monospacedDigit()
                } else {
                    Image(systemName: "bolt.fill").foregroundStyle(accent)
                }
            } minimal: {
                Image(systemName: "bolt.fill").foregroundStyle(accent)
            }
        }
    }

    private var accent: Color {
        Color(red: 1.0, green: 0.58, blue: 0.08)
    }
}

private struct BellwireLiveActivityLockScreen: View {
    let context: ActivityViewContext<BellwireActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(context.attributes.projectName, systemImage: context.attributes.projectIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let value = context.state.value {
                    Text(value)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
            }
            Text(context.state.title)
                .font(.headline)
                .lineLimit(1)
            if let progress = context.state.progress {
                ProgressView(value: progress).tint(accent)
            } else if let subtitle = context.state.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .widgetURL(widgetURL)
    }

    private var accent: Color {
        Color(red: 1.0, green: 0.58, blue: 0.08)
    }

    private var widgetURL: URL? {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "BellwireURLScheme") as? String
            ?? "bellwire"
        return URL(string: "\(scheme)://home")
    }
}
