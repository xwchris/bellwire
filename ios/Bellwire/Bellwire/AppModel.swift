// SPDX-License-Identifier: MPL-2.0
import AuthenticationServices
import CryptoKit
import Security
import SwiftUI
import UIKit
import UserNotifications

enum NotificationPermissionState: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized

    var label: String {
        switch self {
        case .unknown: return "Checking"
        case .notDetermined: return "Not requested"
        case .denied: return "Off"
        case .authorized: return "On"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var liveSurfaces: [LiveSurfaceRecord] = []
    @Published private(set) var events: [InboxEvent] = []
    @Published private(set) var devices: [DeviceRecord] = []
    @Published private(set) var notificationPermission: NotificationPermissionState = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isMarkingAllRead = false
    @Published private(set) var isCreatingDemo = false
    @Published var errorMessage: String?
    @Published var binding: BindingResponse?
    @Published var pendingEventID: String?

    private let keychain = KeychainStore()
    private var currentNonce: String?
    private var apnsToken: String?

    lazy var api = APIClient { [weak self] in
        guard let self else { throw ClientError.signedOut }
        return try await self.validAccessToken()
    }

    init() {
        session = keychain.read()
    }

    var isAuthenticated: Bool { session != nil }
    var unreadCount: Int { events.filter(\.isUnread).count }
    var todayCount: Int {
        events.filter { event in
            guard let date = event.receivedDate else { return false }
            return Calendar.current.isDateInToday(date)
        }.count
    }

    func bootstrap() async {
        await refreshNotificationStatus()
        guard isAuthenticated else { return }
        if notificationPermission == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await loadDashboard(showLoading: true)
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>) async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  let codeData = credential.authorizationCode,
                  let authorizationCode = String(data: codeData, encoding: .utf8),
                  let nonce = currentNonce
            else { throw ClientError.api(code: "APPLE_TOKEN_MISSING", message: "Apple did not return valid authorization credentials.") }
            let newSession = try await api.exchangeAppleIdentityToken(identityToken, nonce: nonce)
            try saveSession(newSession)
            do {
                try await api.saveAppleAuthorizationCode(authorizationCode)
            } catch {
                signOut()
                throw error
            }
            await loadDashboard(showLoading: true)
            if let apnsToken {
                await registerDevice(apnsToken)
            } else if notificationPermission == .authorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            errorMessage = friendlyMessage(error)
        }
        currentNonce = nil
    }

    func loadDashboard(showLoading: Bool = false) async {
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }
        do {
            async let projectRequest: ProjectsResponse = api.request("v1/projects")
            async let surfaceRequest: LiveSurfacesResponse = api.request("v1/surfaces")
            async let inboxRequest: InboxResponse = api.request("v1/inbox?limit=60")
            async let deviceRequest: DevicesResponse = api.request("v1/devices")
            let (projectResponse, surfaceResponse, inboxResponse, deviceResponse) = try await (
                projectRequest,
                surfaceRequest,
                inboxRequest,
                deviceRequest
            )
            projects = projectResponse.projects.sorted(by: stableProjectOrder)
            let projectOrders = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.displayOrder) })
            liveSurfaces = surfaceResponse.surfaces.sorted { left, right in
                let leftProjectOrder = projectOrders[left.projectId] ?? Int.max
                let rightProjectOrder = projectOrders[right.projectId] ?? Int.max
                if leftProjectOrder != rightProjectOrder { return leftProjectOrder < rightProjectOrder }
                if left.displayOrder != right.displayOrder { return left.displayOrder < right.displayOrder }
                return left.id < right.id
            }
            events = inboxResponse.events
            devices = deviceResponse.devices
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func loadEvent(id: String) async throws -> EventDetail {
        try await api.request("v1/events/\(id)")
    }

    func loadProject(id: String) async throws -> (ProjectOverview, [InboxEvent]) {
        async let overviewRequest: ProjectOverview = api.request("v1/projects/\(id)")
        async let eventsRequest: EventPage = api.request("v1/projects/\(id)/events?limit=30")
        let (overview, page) = try await (overviewRequest, eventsRequest)
        let summary = ProjectSummary(
            id: overview.id,
            name: overview.name,
            slug: overview.slug,
            icon: overview.icon,
            logoUrl: overview.logoUrl,
            displayOrder: overview.displayOrder,
            category: overview.category,
            status: overview.status,
            endpoint: overview.endpoint,
            createdAt: overview.createdAt,
            updatedAt: overview.updatedAt
        )
        return (overview, page.events.map { $0.inboxEvent(project: summary) })
    }

    func setProjectPaused(id: String, paused: Bool) async throws -> ProjectSummary {
        let updated: ProjectSummary = try await api.request(
            "v1/projects/\(id)",
            method: .patch,
            body: UpdateProjectPayload(status: paused ? "paused" : "active")
        )
        if let index = projects.firstIndex(where: { $0.id == id }) { projects[index] = updated }
        return updated
    }

    func deleteProject(id: String) async throws {
        try await api.requestVoid("v1/projects/\(id)", method: .delete)
        projects.removeAll { $0.id == id }
        liveSurfaces.removeAll { $0.projectId == id }
        events.removeAll { $0.projectId == id }
    }

    private func stableProjectOrder(_ left: ProjectSummary, _ right: ProjectSummary) -> Bool {
        if left.displayOrder != right.displayOrder { return left.displayOrder < right.displayOrder }
        return left.id < right.id
    }

    @discardableResult
    func deleteAccount() async -> Bool {
        errorMessage = nil
        do {
            try await api.requestVoid("v1/account", method: .delete)
            signOut()
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func createDemoExperience() async {
        guard !isCreatingDemo else { return }
        isCreatingDemo = true
        errorMessage = nil
        defer { isCreatingDemo = false }
        do {
            try await api.requestVoid("v1/demo", method: .post)
            await loadDashboard()
            BellwireHaptics.success()
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func markRead(id: String) async {
        guard let index = events.firstIndex(where: { $0.id == id }), events[index].isUnread else { return }
        do {
            let response: ReadResponse = try await api.request("v1/events/\(id)/read", method: .post)
            let old = events[index]
            events[index] = InboxEvent(
                id: old.id,
                projectId: old.projectId,
                eventType: old.eventType,
                data: old.data,
                occurredAt: old.occurredAt,
                receivedAt: old.receivedAt,
                status: old.status,
                readAt: response.readAt,
                project: old.project,
                sensitiveFields: old.sensitiveFields
            )
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    @discardableResult
    func markAllRead() async -> Int {
        guard unreadCount > 0, !isMarkingAllRead else { return 0 }
        isMarkingAllRead = true
        defer { isMarkingAllRead = false }
        do {
            let response: ReadAllResponse = try await api.request("v1/inbox/read-all", method: .post)
            events = events.map { event in
                guard event.isUnread else { return event }
                return InboxEvent(
                    id: event.id,
                    projectId: event.projectId,
                    eventType: event.eventType,
                    data: event.data,
                    occurredAt: event.occurredAt,
                    receivedAt: event.receivedAt,
                    status: event.status,
                    readAt: response.readAt,
                    project: event.project,
                    sensitiveFields: event.sensitiveFields
                )
            }
            return response.updatedCount
        } catch {
            errorMessage = friendlyMessage(error)
            return 0
        }
    }

    func createBinding() async {
        do {
            let response: BindingResponse = try await api.request("v1/device-bindings", method: .post)
            binding = response
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshNotificationStatus()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            errorMessage = "Notification permission could not be requested."
        }
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notificationPermission = .notDetermined
        case .denied: notificationPermission = .denied
        case .authorized, .provisional, .ephemeral: notificationPermission = .authorized
        @unknown default: notificationPermission = .unknown
        }
    }

    func receivedAPNsToken(_ token: String) async {
        apnsToken = token
        guard isAuthenticated else { return }
        await registerDevice(token)
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "bellwire", url.host == "events" else { return }
        let id = url.pathComponents.dropFirst().first
        if let id, !id.isEmpty { pendingEventID = id }
    }

    func signOut() {
        keychain.delete()
        session = nil
        projects = []
        liveSurfaces = []
        events = []
        devices = []
        binding = nil
        pendingEventID = nil
    }

    private func registerDevice(_ token: String) async {
        struct Payload: Encodable {
            let name: String
            let apnsToken: String
            let appVersion: String
            let installationId: String
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        do {
            let installationId = try keychain.installationID()
            let _: DeviceRecord = try await api.request(
                "v1/devices",
                method: .post,
                body: Payload(
                    name: UIDevice.current.name,
                    apnsToken: token,
                    appVersion: version,
                    installationId: installationId
                )
            )
            let response: DevicesResponse = try await api.request("v1/devices")
            devices = response.devices
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private func validAccessToken() async throws -> String {
        guard var current = session else { throw ClientError.signedOut }
        if current.needsRefresh {
            current = try await api.refreshSession(current.refreshToken)
            try saveSession(current)
        }
        return current.accessToken
    }

    private func saveSession(_ value: AuthSession) throws {
        try keychain.save(value)
        session = value
    }

    private func friendlyMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Connection failed. Please try again."
    }

    private func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }
            for byte in bytes where remaining > 0 {
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }
        return result
    }
}
