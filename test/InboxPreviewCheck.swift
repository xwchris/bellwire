// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct InboxPreviewCheck {
    static func main() throws {
        let payload = """
        {
          "id": "event-1",
          "projectId": "project-1",
          "eventType": "payment.success",
          "data": {
            "amount": 99,
            "message": "Safe preview",
            "customer": "Private customer"
          },
          "occurredAt": "2026-07-21T01:00:00Z",
          "receivedAt": "2026-07-21T01:00:00Z",
          "status": "accepted",
          "readAt": null,
          "project": {
            "id": "project-1",
            "name": "Store",
            "icon": "bolt"
          },
          "sensitiveFields": ["amount", "customer"]
        }
        """
        let event = try JSONDecoder().decode(InboxEvent.self, from: Data(payload.utf8))
        guard event.preview == "Safe preview" else {
            throw PreviewCheckError.unexpectedPreview(event.preview)
        }

        var legacyObject = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        legacyObject.removeValue(forKey: "sensitiveFields")
        let legacyPayload = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyEvent = try JSONDecoder().decode(InboxEvent.self, from: legacyPayload)
        guard legacyEvent.preview.isEmpty else {
            throw PreviewCheckError.unexpectedPreview(legacyEvent.preview)
        }
        guard Set(legacyEvent.sensitiveFields) == Set(["amount", "message", "customer"]) else {
            throw PreviewCheckError.unsafeClassification
        }

        var detailObject = legacyObject
        detailObject["idempotencyKey"] = "order-1"
        detailObject["deliveries"] = []
        let legacyDetailPayload = try JSONSerialization.data(withJSONObject: detailObject)
        let legacyDetail = try JSONDecoder().decode(EventDetail.self, from: legacyDetailPayload)
        guard Set(legacyDetail.sensitiveFields) == Set(legacyDetail.data.keys) else {
            throw PreviewCheckError.unsafeClassification
        }
    }
}

enum PreviewCheckError: Error {
    case unexpectedPreview(String)
    case unsafeClassification
}
