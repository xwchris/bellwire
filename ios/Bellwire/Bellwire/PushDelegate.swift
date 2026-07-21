import UIKit
import UserNotifications

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel? {
        didSet {
            guard let model, let pendingAPNsToken else { return }
            self.pendingAPNsToken = nil
            Task { @MainActor in await model.receivedAPNsToken(pendingAPNsToken) }
        }
    }
    private var pendingAPNsToken: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        guard model != nil else {
            pendingAPNsToken = token
            return
        }
        Task { @MainActor [weak self] in
            await self?.model?.receivedAPNsToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.model?.errorMessage = "This device could not register for push notifications."
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let deepLink = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: deepLink)
        else { return }
        await MainActor.run { [weak self] in self?.model?.handleDeepLink(url) }
    }
}
