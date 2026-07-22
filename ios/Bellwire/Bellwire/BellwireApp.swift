import SwiftUI

@main
struct BellwireApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var model = AppModel()
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale, AppLanguage.selected(from: appLanguage).locale)
                .preferredColorScheme(AppAppearance.selected(from: appAppearance).colorScheme)
                .tint(BellwireTheme.accent)
                .onAppear { pushDelegate.model = model }
                .onOpenURL { model.handleDeepLink($0) }
        }
    }
}
