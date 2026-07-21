import SwiftUI

@main
struct BellwireApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(BellwireTheme.accent)
                .onAppear { pushDelegate.model = model }
                .onOpenURL { model.handleDeepLink($0) }
        }
    }
}
