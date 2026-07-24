// SPDX-License-Identifier: MPL-2.0
import ActivityKit
import Foundation

struct BellwireNativeSurface: Codable, Hashable, Identifiable {
    let id: String
    let projectID: String
    let projectName: String
    let projectIcon: String
    let title: String
    let subtitle: String?
    let value: String?
    let progress: Double?
    let updatedAt: Date
}

struct BellwireWidgetSnapshot: Codable {
    let isPro: Bool
    let updatedAt: Date
    let surfaces: [BellwireNativeSurface]
}

struct BellwireActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let subtitle: String?
        let value: String?
        let progress: Double?
        let updatedAt: Date
    }

    let surfaceID: String
    let projectName: String
    let projectIcon: String
}
