// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Security
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private static let maximumLogoBytes: Int64 = 5 * 1_024 * 1_024
    private static let maximumDetailBytes = 64 * 1_024
    private static let sharedKeychainService = "app.bellwire.direct-shared"
    private static let sharedContextAccount = "notification-context-v2"

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var detailTask: URLSessionDataTask?
    private var logoTask: URLSessionDownloadTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = content

        if content.userInfo["bellwireDeliveryMode"] as? String == "private",
           content.userInfo["protocolVersion"] as? Int == 2,
           let projectID = content.userInfo["projectId"] as? String,
           let reference = content.userInfo["privateWakeRef"] as? String,
           isValidReference(reference),
           let context = readDirectContext(),
           let manifest = context.manifests.first(where: { $0.project.id == projectID }),
           let detailURL = manifest.notificationURL(reference: reference),
           let request = signedRequest(
               url: detailURL,
               context: context,
               connectionID: manifest.connectionId
           ) {
            fetchDetail(request, expectedReference: reference, content: content)
            return
        }

        loadLogo(from: content.userInfo["projectLogoUrl"] as? String, content: content)
    }

    override func serviceExtensionTimeWillExpire() {
        detailTask?.cancel()
        logoTask?.cancel()
        if let bestAttemptContent { finish(with: bestAttemptContent) }
    }

    private func fetchDetail(
        _ request: URLRequest,
        expectedReference: String,
        content: UNMutableNotificationContent
    ) {
        detailTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let data,
                  data.count <= Self.maximumDetailBytes,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let detail = try? JSONDecoder().decode(DirectNotificationDetail.self, from: data),
                  detail.isValid,
                  detail.reference == expectedReference
            else {
                self?.loadLogo(
                    from: content.userInfo["projectLogoUrl"] as? String,
                    content: content
                )
                return
            }

            content.title = detail.title
            content.body = detail.body
            if let subtitle = detail.subtitle { content.subtitle = subtitle }
            self.bestAttemptContent = content
            self.loadLogo(
                from: detail.logoUrl ?? content.userInfo["projectLogoUrl"] as? String,
                content: content
            )
        }
        detailTask?.resume()
    }

    private func loadLogo(from rawURL: String?, content: UNMutableNotificationContent) {
        guard let rawURL,
              let logoURL = URL(string: rawURL),
              logoURL.scheme?.lowercased() == "https"
        else {
            finish(with: content)
            return
        }

        var logoRequest = URLRequest(url: logoURL)
        logoRequest.cachePolicy = .returnCacheDataElseLoad
        logoRequest.timeoutInterval = 8
        logoTask = URLSession.shared.downloadTask(with: logoRequest) { [weak self] temporaryURL, response, _ in
            guard let self,
                  let temporaryURL,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  httpResponse.expectedContentLength <= Self.maximumLogoBytes,
                  httpResponse.mimeType?.lowercased().hasPrefix("image/") == true,
                  let attachment = self.makeAttachment(from: temporaryURL, response: httpResponse)
            else {
                self?.finish(with: content)
                return
            }
            content.attachments = [attachment]
            self.bestAttemptContent = content
            self.finish(with: content)
        }
        logoTask?.resume()
    }

    private func signedRequest(
        url: URL,
        context: SharedDirectNotificationContext,
        connectionID: String
    ) -> URLRequest? {
        guard let privateKeyData = Data(base64Encoded: context.signingPrivateKey),
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
        else { return nil }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath.isEmpty == false
            ? components?.percentEncodedPath
            : "/") ?? "/"
        let target = components?.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        let emptyHash = SHA256.hash(data: Data())
            .map { String(format: "%02x", $0) }
            .joined()
        let canonical = ["GET", target, timestamp, nonce, emptyHash].joined(separator: "\n")
        guard let signature = try? privateKey.signature(for: Data(canonical.utf8))
            .rawRepresentation
            .base64EncodedString()
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            Locale.preferredLanguages.first ?? "en",
            forHTTPHeaderField: "Accept-Language"
        )
        request.setValue(connectionID, forHTTPHeaderField: "X-Bellwire-Connection")
        request.setValue(context.keyID, forHTTPHeaderField: "X-Bellwire-Key-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Bellwire-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Bellwire-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Bellwire-Signature")
        return request
    }

    private func readDirectContext() -> SharedDirectNotificationContext? {
        guard let accessGroup = Bundle.main.object(
            forInfoDictionaryKey: "BellwireKeychainAccessGroup"
        ) as? String else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.sharedKeychainService,
            kSecAttrAccount as String: Self.sharedContextAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(SharedDirectNotificationContext.self, from: data)
    }

    private func isValidReference(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{22,200}$"#, options: .regularExpression) != nil
    }

    private func makeAttachment(
        from temporaryURL: URL,
        response: HTTPURLResponse
    ) -> UNNotificationAttachment? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize <= Self.maximumLogoBytes
        else { return nil }
        let fileExtension = preferredFileExtension(response: response)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            return try UNNotificationAttachment(identifier: "project-logo", url: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private func preferredFileExtension(response: HTTPURLResponse) -> String {
        if let suggested = response.suggestedFilename {
            let fileExtension = URL(fileURLWithPath: suggested).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(fileExtension) {
                return fileExtension
            }
        }
        switch response.mimeType?.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        default: return "png"
        }
    }

    private func finish(with content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }
}

private struct SharedDirectNotificationContext: Decodable {
    let keyID: String
    let signingPrivateKey: String
    let manifests: [DirectConnectionManifest]
}

private struct DirectConnectionManifest: Decodable {
    let version: Int
    let connectionId: String
    let baseUrl: String
    let endpoints: DirectEndpointsManifest
    let project: DirectProjectManifest

    func notificationURL(reference: String) -> URL? {
        guard version == 2,
              let base = URL(string: baseUrl),
              base.scheme?.lowercased() == "https",
              base.user == nil,
              base.password == nil,
              endpoints.notification.hasPrefix("/"),
              !endpoints.notification.hasPrefix("//"),
              let rawURL = URL(string: endpoints.notification, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)
        else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "ref" }
        queryItems.append(URLQueryItem(name: "ref", value: reference))
        components.queryItems = queryItems
        return components.url
    }
}

private struct DirectEndpointsManifest: Decodable {
    let notification: String
}

private struct DirectProjectManifest: Decodable {
    let id: String
}

private struct DirectNotificationDetail: Decodable {
    let reference: String
    let eventType: String
    let title: String
    let body: String
    let subtitle: String?
    let occurredAt: String
    let data: [String: JSONValue]
    let deepLink: String?
    let logoUrl: String?

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= 240
            && body.count <= 1_000
            && (subtitle?.count ?? 0) <= 240
            && reference.range(
                of: #"^[A-Za-z0-9_-]{22,200}$"#,
                options: .regularExpression
            ) != nil
            && !eventType.isEmpty
            && Self.validISO8601Date(occurredAt)
            && validHTTPSURL(logoUrl)
            && validDeepLink(deepLink)
    }

    private func validHTTPSURL(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let url = URL(string: value) else { return false }
        return url.scheme?.lowercased() == "https"
            && url.user == nil
            && url.password == nil
            && url.host != nil
    }

    private func validDeepLink(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return ["https", "bellwire"].contains(scheme)
    }

    private static func validISO8601Date(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }
}
