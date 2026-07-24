// SPDX-License-Identifier: MPL-2.0
import ActivityKit
import Foundation
import WidgetKit

@MainActor
final class NativeDisplayManager {
    static let shared = NativeDisplayManager()

    private let snapshotFilename = "bellwire-widget-snapshot.json"

    private init() {}

    func synchronize(
        surfaces: [LiveSurfaceRecord],
        isPro: Bool
    ) async {
        let nativeSurfaces = surfaces.prefix(10).map(Self.nativeSurface)
        writeSnapshot(
            BellwireWidgetSnapshot(
                isPro: isPro,
                updatedAt: .now,
                surfaces: nativeSurfaces
            )
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "BellwireSurfaces")

        let byID = Dictionary(uniqueKeysWithValues: nativeSurfaces.map { ($0.id, $0) })
        for activity in Activity<BellwireActivityAttributes>.activities {
            guard isPro, let surface = byID[activity.attributes.surfaceID] else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            await activity.update(
                ActivityContent(
                    state: Self.contentState(surface),
                    staleDate: Date().addingTimeInterval(15 * 60)
                )
            )
        }
    }

    func startLiveActivity(for surface: LiveSurfaceRecord) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw NativeDisplayError.liveActivitiesDisabled
        }
        let native = Self.nativeSurface(surface)
        for activity in Activity<BellwireActivityAttributes>.activities
        where activity.attributes.surfaceID == surface.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        _ = try Activity.request(
            attributes: BellwireActivityAttributes(
                surfaceID: native.id,
                projectName: native.projectName,
                projectIcon: native.projectIcon
            ),
            content: ActivityContent(
                state: Self.contentState(native),
                staleDate: Date().addingTimeInterval(15 * 60)
            ),
            pushType: nil
        )
    }

    func stopLiveActivity(surfaceID: String) async {
        for activity in Activity<BellwireActivityAttributes>.activities
        where activity.attributes.surfaceID == surfaceID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func isLive(surfaceID: String) -> Bool {
        Activity<BellwireActivityAttributes>.activities.contains {
            $0.attributes.surfaceID == surfaceID
        }
    }

    func clear() async {
        writeSnapshot(
            BellwireWidgetSnapshot(isPro: false, updatedAt: .now, surfaces: [])
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "BellwireSurfaces")
        for activity in Activity<BellwireActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func writeSnapshot(_ snapshot: BellwireWidgetSnapshot) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else { return }
        let url = container.appendingPathComponent(snapshotFilename)
        guard let data = try? JSONEncoder.bellwireNative.encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "BellwireAppGroup") as? String
            ?? "group.app.bellwire.shared"
    }

    private static func nativeSurface(_ surface: LiveSurfaceRecord) -> BellwireNativeSurface {
        let progress: Double?
        if let percentage = surface.content["percentage"]?.numberValue {
            progress = min(max(percentage / 100, 0), 1)
        } else if let value = surface.content["value"]?.numberValue,
                  let upper = surface.content["upperLimit"]?.numberValue,
                  upper > 0 {
            progress = min(max(value / upper, 0), 1)
        } else {
            progress = nil
        }
        let metric = surface.metrics.first
        let directValue = surface.content["displayValue"]?.displayValue
            ?? surface.content["value"]?.displayValue
        let value = metric.map { $0.value.displayValue + ($0.unit ?? "") } ?? directValue
        return BellwireNativeSurface(
            id: surface.id,
            projectID: surface.projectId,
            projectName: surface.project?.name ?? "Bellwire",
            projectIcon: surface.project?.icon ?? "rectangle.3.group",
            title: surface.title,
            subtitle: surface.subtitle,
            value: value,
            progress: progress,
            updatedAt: surface.updatedDate ?? .now
        )
    }

    private static func contentState(
        _ surface: BellwireNativeSurface
    ) -> BellwireActivityAttributes.ContentState {
        .init(
            title: surface.title,
            subtitle: surface.subtitle,
            value: surface.value,
            progress: surface.progress,
            updatedAt: surface.updatedAt
        )
    }
}

enum NativeDisplayError: LocalizedError {
    case liveActivitiesDisabled

    var errorDescription: String? {
        switch self {
        case .liveActivitiesDisabled:
            String(localized: "Live Activities are disabled in iPhone Settings.")
        }
    }
}

private extension JSONEncoder {
    static var bellwireNative: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
