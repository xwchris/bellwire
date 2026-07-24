// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Security
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private static let maximumLogoBytes: Int64 = 5 * 1_024 * 1_024
    private static let maximumDetailBytes = 64 * 1_024
    private static let sharedKeychainService = "app.bellwire.direct-shared"
    private static let sharedContextAccount = "notification-context-v1"

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

        if content.userInfo["bellwireNotificationMode"] as? String == "local_enrichment",
           let projectID = content.userInfo["projectId"] as? String,
           let reference = content.userInfo["directNotificationRef"] as? String,
           isValidReference(reference),
           let context = readDirectContext(),
           let manifest = context.manifests.first(where: { $0.project.id == projectID }),
           let detailURL = manifest.notificationURL(reference: reference),
           let request = signedRequest(
               url: detailURL,
               context: context,
               connectionID: manifest.connectionId
           ) {
            fetchDetail(request, content: content)
            return
        }

        loadLogo(from: content.userInfo["projectLogoUrl"] as? String, content: content)
    }

    override func serviceExtensionTimeWillExpire() {
        detailTask?.cancel()
        logoTask?.cancel()
        if let bestAttemptContent { finish(with: bestAttemptContent) }
    }

    private func fetchDetail(_ request: URLRequest, content: UNMutableNotificationContent) {
        detailTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let data,
                  data.count <= Self.maximumDetailBytes,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let detail = try? JSONDecoder().decode(DirectNotificationDetail.self, from: data),
                  detail.isValid
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
        value.range(of: #"^[A-Za-z0-9._~-]{8,200}$"#, options: .regularExpression) != nil
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
    let notificationPath: String?
    let project: DirectProjectManifest

    func notificationURL(reference: String) -> URL? {
        guard version == 1,
              let notificationPath,
              let base = URL(string: baseUrl),
              base.scheme?.lowercased() == "https",
              base.user == nil,
              base.password == nil,
              notificationPath.hasPrefix("/"),
              !notificationPath.hasPrefix("//"),
              let rawURL = URL(string: notificationPath, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)
        else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "ref" }
        queryItems.append(URLQueryItem(name: "ref", value: reference))
        components.queryItems = queryItems
        return components.url
    }
}

private struct DirectProjectManifest: Decodable {
    let id: String
}

private struct DirectNotificationDetail: Decodable {
    let title: String
    let body: String
    let subtitle: String?
    let logoUrl: String?

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= 120
            && body.count <= 240
            && (subtitle?.count ?? 0) <= 120
            && (logoUrl == nil || URL(string: logoUrl!)?.scheme?.lowercased() == "https")
    }
}
