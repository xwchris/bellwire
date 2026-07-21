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

    var body: some View {
        TabView(selection: $selection) {
            InboxView()
                .tag(MainTab.home)
                .tabItem { Label("Home", systemImage: BellwireIcons.home) }
            ProjectsView()
                .tag(MainTab.projects)
                .tabItem { Label("Projects", systemImage: BellwireIcons.projects) }
            EventsView()
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
