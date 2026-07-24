// SPDX-License-Identifier: MPL-2.0
import SwiftUI

@main
struct BellwireApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var model = AppModel()
    @StateObject private var purchaseManager = PurchaseManager()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(purchaseManager)
                .environment(\.locale, AppLanguage.selected(from: appLanguage).locale)
                .preferredColorScheme(AppAppearance.selected(from: appAppearance).colorScheme)
                .tint(BellwireTheme.accent)
                .onAppear { pushDelegate.model = model }
                .task {
                    purchaseManager.configure(
                        transactionUploader: { signedTransactionInfo, source in
                            try await model.submitAppleTransaction(
                                signedTransactionInfo,
                                source: source
                            )
                        },
                        entitlementLoader: {
                            try await model.refreshServerEntitlement()
                        }
                    )
                    if model.isAuthenticated {
                        await purchaseManager.prepare()
                    }
                }
                .onChange(of: model.isAuthenticated) { _, isAuthenticated in
                    guard isAuthenticated else { return }
                    Task { await purchaseManager.prepare() }
                }
                .onOpenURL { model.handleDeepLink($0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await model.handleBecameActive()
                        await purchaseManager.refreshEntitlements()
                    }
                }
        }
    }
}
