// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("notificationOnboardingSeen") private var notificationOnboardingSeen = false

    var body: some View {
        Group {
            if !model.isAuthenticated {
                WelcomeView()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !notificationOnboardingSeen {
                NotificationOnboardingView(isComplete: $notificationOnboardingSeen)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        .background(BellwireTheme.background.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.isAuthenticated)
        .task { await model.bootstrap() }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: MainTab = .home
    @State private var eventsFilter: EventFilter = .all

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-BellwireScreenshot"),
           arguments.indices.contains(index + 1) {
            let tab: MainTab
            switch arguments[index + 1] {
            case "projects": tab = .projects
            case "events": tab = .events
            case "settings": tab = .settings
            default: tab = .home
            }
            _selection = State(initialValue: tab)
        }
#endif
    }

    var body: some View {
        TabView(selection: $selection) {
            InboxView { preferUnread in
                eventsFilter = preferUnread ? .unread : .all
                selection = .events
            }
                .tag(MainTab.home)
                .tabItem { Label("Home", systemImage: BellwireIcons.home) }
            ProjectsView()
                .tag(MainTab.projects)
                .tabItem { Label("Projects", systemImage: BellwireIcons.projects) }
            EventsView(filter: $eventsFilter)
                .tag(MainTab.events)
                .tabItem { Label("Events", systemImage: BellwireIcons.events) }
                .badge(model.unreadCount)
            SettingsView()
                .tag(MainTab.settings)
                .tabItem { Label("Settings", systemImage: BellwireIcons.settings) }
        }
        .toolbarBackground(BellwireTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: model.pendingEventID) { _, eventID in
            if eventID != nil { selection = .home }
        }
    }
}

private enum MainTab: Hashable {
    case home
    case projects
    case events
    case settings
}
