import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private static let maximumLogoBytes: Int64 = 5 * 1_024 * 1_024

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?

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

        guard let rawURL = content.userInfo["projectLogoUrl"] as? String,
              let logoURL = URL(string: rawURL),
              logoURL.scheme?.lowercased() == "https"
        else {
            finish(with: content)
            return
        }

        var logoRequest = URLRequest(url: logoURL)
        logoRequest.cachePolicy = .returnCacheDataElseLoad
        logoRequest.timeoutInterval = 12
        downloadTask = URLSession.shared.downloadTask(with: logoRequest) { [weak self] temporaryURL, response, _ in
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
            self.finish(with: content)
        }
        downloadTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        if let bestAttemptContent { finish(with: bestAttemptContent) }
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
