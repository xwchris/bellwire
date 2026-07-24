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
    @Published private(set) var agentConnections: [AgentConnectionRecord] = []
    @Published private(set) var revokingAgentConnectionID: String?
    @Published private(set) var notificationPermission: NotificationPermissionState = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isMarkingAllRead = false
    @Published private(set) var isCreatingDemo = false
    @Published private(set) var lastDashboardRefreshAt: Date?
    @Published var errorMessage: String?
    @Published var binding: BindingResponse?
    @Published var pendingEventID: String?

    private let keychain = KeychainStore()
    private var currentNonce: String?
    private var apnsToken: String?
    private var dashboardLoadTask: Task<Void, Never>?
    private var dashboardLoadID: UUID?
    private var sessionRefreshTask: Task<AuthSession, Error>?

    lazy var api = APIClient { [weak self] in
        guard let self else { throw ClientError.signedOut }
        return try await self.validAccessToken()
    }

    init() {
#if DEBUG
        if let mode = Self.screenshotMode {
            session = mode == "welcome" ? nil : AuthSession(
                accessToken: "app-store-screenshot",
                refreshToken: "app-store-screenshot",
                expiresAt: .distantFuture,
                user: AuthUser(id: "screenshot-user", email: "hello@bellwire.app")
            )
            if mode != "welcome" {
                UserDefaults.standard.set(true, forKey: "notificationOnboardingSeen")
                loadScreenshotFixtures()
            }
            return
        }
#endif
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
#if DEBUG
        if Self.screenshotMode != nil { return }
#endif
        await refreshNotificationStatus()
        guard isAuthenticated else { return }
        if notificationPermission == .authorized, apnsToken == nil {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await loadDashboard(showLoading: true)
    }

    func handleBecameActive() async {
#if DEBUG
        if Self.screenshotMode != nil { return }
#endif
        await refreshNotificationStatus()
        guard isAuthenticated else { return }
        if notificationPermission == .authorized, apnsToken == nil {
            UIApplication.shared.registerForRemoteNotifications()
        }
        if lastDashboardRefreshAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true {
            await loadDashboard()
        }
    }

#if DEBUG
    private static var screenshotMode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-BellwireScreenshot"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private func loadScreenshotFixtures() {
        let now = "2026-07-22T16:28:00Z"
        let earlier = "2026-07-22T16:15:00Z"
        let store = ProjectSummary(
            id: "store", name: "Northstar Store", slug: "northstar-store", icon: "cart.fill",
            logoUrl: nil, displayOrder: 0, category: "commerce", status: "active",
            endpoint: "https://api.bellwire.app/v1/ingest/demo", createdAt: earlier, updatedAt: now
        )
        let agent = ProjectSummary(
            id: "agent", name: "Weekly Report Agent", slug: "weekly-report-agent", icon: "gearshape.2.fill",
            logoUrl: nil, displayOrder: 1, category: "automation", status: "active",
            endpoint: "https://api.bellwire.app/v1/ingest/demo", createdAt: earlier, updatedAt: now
        )
        let deploy = ProjectSummary(
            id: "deploy", name: "Production Deploy", slug: "production-deploy", icon: "shippingbox.fill",
            logoUrl: nil, displayOrder: 2, category: "engineering", status: "active",
            endpoint: "https://api.bellwire.app/v1/ingest/demo", createdAt: earlier, updatedAt: now
        )
        projects = [store, agent, deploy]
        liveSurfaces = [
            LiveSurfaceRecord(
                id: "surface-agent", projectId: agent.id, surfaceKey: "weekly-run", type: "progress",
                title: "Weekly report", subtitle: "Analyzing 18 sources", content: [
                    "percentage": .number(72),
                    "metrics": .array([
                        .object(["label": .string("Sources"), "value": .number(18)]),
                        .object(["label": .string("Complete"), "value": .string("72%")])
                    ])
                ], action: nil, displayOrder: 0, version: 1, createdAt: earlier, updatedAt: now,
                project: EventProject(id: agent.id, name: agent.name, icon: agent.icon, logoUrl: nil)
            )
        ]
        events = [
            InboxEvent(
                id: "payment", projectId: store.id, eventType: "payment.received",
                data: ["amount": .string("$128.00"), "product": .string("Creator Plan")],
                occurredAt: now, receivedAt: now, status: "delivered", readAt: nil,
                project: EventProject(id: store.id, name: store.name, icon: store.icon, logoUrl: nil),
                sensitiveFields: []
            ),
            InboxEvent(
                id: "agent-run", projectId: agent.id, eventType: "agent.run.in_progress",
                data: ["status": .string("Running"), "message": .string("Weekly report")],
                occurredAt: earlier, receivedAt: earlier, status: "delivered", readAt: nil,
                project: EventProject(id: agent.id, name: agent.name, icon: agent.icon, logoUrl: nil),
                sensitiveFields: []
            ),
            InboxEvent(
                id: "deployment", projectId: deploy.id, eventType: "deployment.completed",
                data: ["status": .string("Production"), "message": .string("Build 184")],
                occurredAt: earlier, receivedAt: earlier, status: "delivered", readAt: earlier,
                project: EventProject(id: deploy.id, name: deploy.name, icon: deploy.icon, logoUrl: nil),
                sensitiveFields: []
            )
        ]
        devices = [
            DeviceRecord(
                id: "iphone", name: "iPhone", platform: "ios", apnsEnvironment: "sandbox", appVersion: "1.0",
                lastActiveAt: now, pushEnabled: true
            )
        ]
        notificationPermission = .authorized
    }
#endif

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
        if let dashboardLoadTask {
            await dashboardLoadTask.value
            return
        }
        if showLoading { isLoading = true }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDashboardLoad()
        }
        let loadID = UUID()
        dashboardLoadTask = task
        dashboardLoadID = loadID
        await task.value
        if dashboardLoadID == loadID {
            dashboardLoadTask = nil
            dashboardLoadID = nil
            if showLoading { isLoading = false }
        }
    }

    private func performDashboardLoad() async {
        guard let userID = session?.user.id else { return }
        let storedDirectConnections = keychain.directConnectionManifests(userID: userID)
        let directProjectIDs = Set(storedDirectConnections.map(\.project.id))
        let cachedDirectProjects = deduplicatedProjects(
            projects.filter { directProjectIDs.contains($0.id) }
        )
        let cachedDirectSurfaces = deduplicatedSurfaces(
            liveSurfaces.filter { directProjectIDs.contains($0.projectId) }
        )
        do {
            async let projectRequest: ProjectsResponse = api.request("v1/projects")
            async let surfaceRequest: LiveSurfacesResponse = api.request("v1/surfaces")
            async let inboxRequest: InboxResponse = api.request("v1/inbox?limit=60")
            async let deviceRequest: DevicesResponse = api.request("v1/devices")
            async let connectionRequest: AgentConnectionsResponse = api.request("v1/agent-connections")
            let (
                projectResponse,
                surfaceResponse,
                inboxResponse,
                deviceResponse,
                connectionResponse
            ) = try await (
                projectRequest,
                surfaceRequest,
                inboxRequest,
                deviceRequest,
                connectionRequest
            )
            guard !Task.isCancelled, session?.user.id == userID else { return }
            let orderedProjects = projectResponse.projects.sorted(by: stableProjectOrder)
            let projectOrders = Dictionary(uniqueKeysWithValues: orderedProjects.map { ($0.id, $0.displayOrder) })
            let orderedSurfaces = surfaceResponse.surfaces.sorted { left, right in
                let leftProjectOrder = projectOrders[left.projectId] ?? Int.max
                let rightProjectOrder = projectOrders[right.projectId] ?? Int.max
                if leftProjectOrder != rightProjectOrder { return leftProjectOrder < rightProjectOrder }
                if left.displayOrder != right.displayOrder { return left.displayOrder < right.displayOrder }
                return left.id < right.id
            }
            let cloudProjects = orderedProjects.filter { !directProjectIDs.contains($0.id) }
            let cloudSurfaces = orderedSurfaces.filter { !directProjectIDs.contains($0.projectId) }
            projects = deduplicatedProjects(cloudProjects + cachedDirectProjects)
                .sorted(by: stableProjectOrder)
            liveSurfaces = sortedSurfaces(
                deduplicatedSurfaces(cloudSurfaces + cachedDirectSurfaces),
                projects: projects
            )
            events = inboxResponse.events
            devices = deviceResponse.devices
            agentConnections = connectionResponse.connections
            lastDashboardRefreshAt = Date()
            errorMessage = nil
            await refreshDirectConnections(userID: userID)
        } catch {
            guard !Task.isCancelled else { return }
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
        if let userID = session?.user.id,
           try keychain.deleteDirectConnection(projectID: id, userID: userID) {
            projects.removeAll { $0.id == id }
            liveSurfaces.removeAll { $0.projectId == id }
            events.removeAll { $0.projectId == id }
            return
        }
        try await api.requestVoid("v1/projects/\(id)", method: .delete)
        projects.removeAll { $0.id == id }
        liveSurfaces.removeAll { $0.projectId == id }
        events.removeAll { $0.projectId == id }
    }

    private func stableProjectOrder(_ left: ProjectSummary, _ right: ProjectSummary) -> Bool {
        if left.displayOrder != right.displayOrder { return left.displayOrder < right.displayOrder }
        return left.id < right.id
    }

    private func deduplicatedProjects(_ values: [ProjectSummary]) -> [ProjectSummary] {
        var projectsByID: [String: ProjectSummary] = [:]
        for project in values {
            projectsByID[project.id] = project
        }
        return Array(projectsByID.values)
    }

    private func deduplicatedSurfaces(_ values: [LiveSurfaceRecord]) -> [LiveSurfaceRecord] {
        var surfacesByKey: [String: LiveSurfaceRecord] = [:]
        for surface in values {
            surfacesByKey["\(surface.projectId):\(surface.surfaceKey)"] = surface
        }
        return Array(surfacesByKey.values)
    }

    private func sortedSurfaces(
        _ values: [LiveSurfaceRecord],
        projects: [ProjectSummary]
    ) -> [LiveSurfaceRecord] {
        let projectOrders = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, $0.displayOrder) }
        )
        return values.sorted { left, right in
            let leftProjectOrder = projectOrders[left.projectId] ?? Int.max
            let rightProjectOrder = projectOrders[right.projectId] ?? Int.max
            if leftProjectOrder != rightProjectOrder {
                return leftProjectOrder < rightProjectOrder
            }
            if left.displayOrder != right.displayOrder {
                return left.displayOrder < right.displayOrder
            }
            return left.id < right.id
        }
    }

    @discardableResult
    func deleteAccount() async -> Bool {
        errorMessage = nil
        do {
            let userID = session?.user.id
            try await api.requestVoid("v1/account", method: .delete)
            if let userID {
                keychain.deleteDirectData(userID: userID)
            }
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
            guard let userID = session?.user.id else { throw ClientError.signedOut }
            struct Payload: Encodable {
                let deviceKey: DeviceKeyDescriptor
            }
            let installationID = try keychain.installationID()
            let identity = try keychain.deviceIdentity(userID: userID)
            let response: BindingResponse = try await api.request(
                "v1/device-bindings",
                method: .post,
                body: Payload(deviceKey: identity.descriptor(installationID: installationID))
            )
            binding = response
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func revokeAgentConnection(id: String) async {
        guard revokingAgentConnectionID == nil else { return }
        revokingAgentConnectionID = id
        defer { revokingAgentConnectionID = nil }
        do {
            try await api.requestVoid("v1/agent-connections/\(id)", method: .delete)
            withAnimation(BellwireAnimation.standard) {
                agentConnections.removeAll { $0.id == id }
            }
            BellwireHaptics.success()
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

    func handleRemoteNotification(deepLink: URL? = nil) {
        if let deepLink { handleDeepLink(deepLink) }
        guard isAuthenticated else { return }
        Task { @MainActor [weak self] in
            await self?.loadDashboard()
        }
    }

    func signOut() {
        dashboardLoadTask?.cancel()
        sessionRefreshTask?.cancel()
        dashboardLoadTask = nil
        dashboardLoadID = nil
        sessionRefreshTask = nil
        keychain.delete()
        session = nil
        projects = []
        liveSurfaces = []
        events = []
        devices = []
        agentConnections = []
        revokingAgentConnectionID = nil
        binding = nil
        pendingEventID = nil
        lastDashboardRefreshAt = nil
        isLoading = false
    }

    private func registerDevice(_ token: String) async {
        struct Payload: Encodable {
            let name: String
            let apnsToken: String
            let apnsEnvironment: String
            let appVersion: String
            let installationId: String
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
#if DEBUG
        let environment = "sandbox"
#else
        let environment = "production"
#endif
        do {
            let installationId = try keychain.installationID()
            let _: DeviceRecord = try await api.request(
                "v1/devices",
                method: .post,
                body: Payload(
                    name: UIDevice.current.name,
                    apnsToken: token,
                    apnsEnvironment: environment,
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
        guard let current = session else { throw ClientError.signedOut }
        guard current.needsRefresh else { return current.accessToken }
        if let sessionRefreshTask {
            return try await sessionRefreshTask.value.accessToken
        }

        let refreshToken = current.refreshToken
        let client = api
        let task = Task { try await client.refreshSession(refreshToken) }
        sessionRefreshTask = task
        do {
            let refreshed = try await task.value
            sessionRefreshTask = nil
            guard session?.refreshToken == refreshToken else { throw ClientError.signedOut }
            try saveSession(refreshed)
            return refreshed.accessToken
        } catch {
            sessionRefreshTask = nil
            throw error
        }
    }

    private func saveSession(_ value: AuthSession) throws {
        try keychain.save(value)
        session = value
    }

    private func refreshDirectConnections(userID: String) async {
        guard let identity = try? keychain.deviceIdentity(userID: userID) else { return }
        var manifests = keychain.directConnectionManifests(userID: userID)
        if let response: DirectConnectionEnvelopesResponse = try? await api.request(
            "v1/direct-connections?deviceKeyId=\(identity.id)"
        ) {
            for envelope in response.envelopes where envelope.deviceKeyId == identity.id {
                guard let plaintext = try? identity.decrypt(envelope),
                      let manifest = try? JSONDecoder().decode(
                        DirectConnectionManifest.self,
                        from: plaintext
                      ),
                      manifest.surfacesURL != nil
                else { continue }
                manifests.removeAll { $0.connectionId == manifest.connectionId }
                manifests.append(manifest)
                do {
                    try keychain.saveDirectConnectionManifests(manifests, userID: userID)
                    try await api.requestVoid(
                        "v1/direct-connections/\(envelope.id)",
                        method: .delete
                    )
                } catch {
                    continue
                }
            }
        }

        for manifest in manifests {
            guard let result = try? await fetchDirectSurfaces(
                manifest: manifest,
                identity: identity
            ) else { continue }
            let nextProjects = deduplicatedProjects(
                projects.filter { $0.id != result.project.id } + [result.project]
            ).sorted(by: stableProjectOrder)
            let nextSurfaces = deduplicatedSurfaces(
                liveSurfaces.filter { $0.projectId != result.project.id } + result.surfaces
            )
            projects = nextProjects
            liveSurfaces = sortedSurfaces(nextSurfaces, projects: nextProjects)
        }
    }

    private func fetchDirectSurfaces(
        manifest: DirectConnectionManifest,
        identity: DeviceIdentity
    ) async throws -> DirectSurfaceResult {
        guard let url = manifest.surfacesURL else {
            throw DirectConnectionError.invalidManifest
        }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = randomNonce()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath.isEmpty == false
            ? components?.percentEncodedPath
            : "/") ?? "/"
        let target = components?.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        let emptyHash = SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }
            .joined()
        let canonical = ["GET", target, timestamp, nonce, emptyHash].joined(separator: "\n")
        let signature = try identity.signature(for: Data(canonical.utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(manifest.connectionId, forHTTPHeaderField: "X-Bellwire-Connection")
        request.setValue(identity.id, forHTTPHeaderField: "X-Bellwire-Key-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Bellwire-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Bellwire-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Bellwire-Signature")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count <= 1_048_576
        else { throw DirectConnectionError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(LiveSurfacesResponse.self, from: data)
        guard payload.surfaces.allSatisfy({ $0.projectId == manifest.project.id }) else {
            throw DirectConnectionError.invalidResponse
        }
        let now = ISO8601DateFormatter.bellwire.string(from: .now)
        let project = ProjectSummary(
            id: manifest.project.id,
            name: manifest.project.name,
            slug: "direct-\(manifest.connectionId)",
            icon: manifest.project.icon,
            logoUrl: manifest.project.logoUrl,
            displayOrder: manifest.project.displayOrder,
            category: "direct",
            status: "active",
            endpoint: manifest.baseUrl,
            createdAt: now,
            updatedAt: now
        )
        return DirectSurfaceResult(project: project, surfaces: payload.surfaces)
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

private struct DirectSurfaceResult {
    let project: ProjectSummary
    let surfaces: [LiveSurfaceRecord]
}
