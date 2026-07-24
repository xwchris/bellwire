// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftData

@Model
final class CachedPrivateEvent {
    @Attribute(.unique) var cacheKey: String
    var accountID: String
    var projectID: String
    var reference: String
    var eventType: String
    var title: String
    var body: String
    var subtitle: String?
    var dataJSON: Data
    var occurredAt: Date
    var fetchedAt: Date
    var readAt: Date?
    var deepLink: String?
    var logoURL: String?

    init(
        accountID: String,
        projectID: String,
        payload: PrivateEventPayload,
        fetchedAt: Date = .now
    ) throws {
        cacheKey = Self.key(accountID: accountID, projectID: projectID, reference: payload.reference)
        self.accountID = accountID
        self.projectID = projectID
        reference = payload.reference
        eventType = payload.eventType
        title = payload.title
        body = payload.body
        subtitle = payload.subtitle
        dataJSON = try JSONEncoder().encode(payload.data)
        occurredAt = ISO8601DateFormatter.bellwireDate(from: payload.occurredAt) ?? fetchedAt
        self.fetchedAt = fetchedAt
        deepLink = payload.deepLink
        logoURL = payload.logoUrl
    }

    static func key(accountID: String, projectID: String, reference: String) -> String {
        "\(accountID.lowercased())|\(projectID.lowercased())|\(reference)"
    }

    var eventID: String { "private:\(projectID):\(reference)" }
    var data: [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: dataJSON)) ?? [:]
    }
}

@MainActor
final class PrivateEventStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) {
        do {
            let schema = Schema([CachedPrivateEvent.self])
            let configuration: ModelConfiguration
            if inMemory {
                configuration = ModelConfiguration(
                    "PrivateEventCache",
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            } else {
                let directory = try Self.protectedStoreDirectory()
                configuration = ModelConfiguration(
                    "PrivateEventCache",
                    schema: schema,
                    url: directory.appending(path: "private-events.store"),
                    cloudKitDatabase: .none
                )
            }
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Private event cache could not be initialized: \(error)")
        }
    }

    func merge(
        accountID: String,
        projectID: String,
        payloads: [PrivateEventPayload],
        fetchedAt: Date = .now
    ) throws {
        let existing = try records(accountID: accountID, projectID: projectID)
        let byReference = Dictionary(uniqueKeysWithValues: existing.map { ($0.reference, $0) })
        for payload in payloads {
            guard Self.validReference(payload.reference) else { continue }
            if let record = byReference[payload.reference] {
                record.eventType = payload.eventType
                record.title = payload.title
                record.body = payload.body
                record.subtitle = payload.subtitle
                record.dataJSON = try JSONEncoder().encode(payload.data)
                record.occurredAt = ISO8601DateFormatter.bellwireDate(from: payload.occurredAt)
                    ?? record.occurredAt
                record.fetchedAt = fetchedAt
                record.deepLink = payload.deepLink
                record.logoURL = payload.logoUrl
            } else {
                context.insert(
                    try CachedPrivateEvent(
                        accountID: accountID,
                        projectID: projectID,
                        payload: payload,
                        fetchedAt: fetchedAt
                    )
                )
            }
        }
        try enforceRetention(accountID: accountID, projectID: projectID, now: fetchedAt)
        try context.save()
    }

    func inboxEvents(accountID: String, projects: [ProjectSummary]) -> [InboxEvent] {
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return (try? records(accountID: accountID))?.compactMap { record in
            guard let project = projectByID[record.projectID] else { return nil }
            return InboxEvent(
                id: record.eventID,
                projectId: record.projectID,
                eventType: record.eventType,
                data: record.data,
                occurredAt: ISO8601DateFormatter.bellwire.string(from: record.occurredAt),
                receivedAt: ISO8601DateFormatter.bellwire.string(from: record.fetchedAt),
                status: "local",
                readAt: record.readAt.map { ISO8601DateFormatter.bellwire.string(from: $0) },
                project: EventProject(
                    id: project.id,
                    name: project.name,
                    icon: project.icon,
                    logoUrl: record.logoURL ?? project.logoUrl
                ),
                sensitiveFields: []
            )
        }.sorted { $0.receivedAt > $1.receivedAt } ?? []
    }

    func event(accountID: String, eventID: String) -> CachedPrivateEvent? {
        (try? records(accountID: accountID).first { $0.eventID == eventID }) ?? nil
    }

    func lastFetchedAt(accountID: String, projectID: String) -> Date? {
        try? records(accountID: accountID, projectID: projectID).first?.fetchedAt
    }

    func exportPayloads(accountID: String, projectID: String) throws -> [PrivateEventPayload] {
        try records(accountID: accountID, projectID: projectID).map { record in
            PrivateEventPayload(
                reference: record.reference,
                eventType: record.eventType,
                title: record.title,
                body: record.body,
                subtitle: record.subtitle,
                occurredAt: ISO8601DateFormatter.bellwire.string(from: record.occurredAt),
                data: record.data,
                deepLink: record.deepLink,
                logoUrl: record.logoURL
            )
        }
    }

    func markRead(accountID: String, eventID: String, at date: Date = .now) throws -> Bool {
        guard let event = event(accountID: accountID, eventID: eventID), event.readAt == nil else {
            return false
        }
        event.readAt = date
        try context.save()
        return true
    }

    func markAllRead(accountID: String, at date: Date = .now) throws -> Int {
        let unread = try records(accountID: accountID).filter { $0.readAt == nil }
        unread.forEach { $0.readAt = date }
        if !unread.isEmpty { try context.save() }
        return unread.count
    }

    func clear(accountID: String) throws {
        for record in try records(accountID: accountID) { context.delete(record) }
        try context.save()
    }

    func clear(accountID: String, projectID: String) throws {
        for record in try records(accountID: accountID, projectID: projectID) {
            context.delete(record)
        }
        try context.save()
    }

    private func records(
        accountID: String,
        projectID: String? = nil
    ) throws -> [CachedPrivateEvent] {
        let targetAccountID = accountID
        var descriptor = FetchDescriptor<CachedPrivateEvent>(
            predicate: #Predicate { $0.accountID == targetAccountID },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5_000
        let values = try context.fetch(descriptor)
        return projectID.map { targetProjectID in
            values.filter { $0.projectID == targetProjectID }
        } ?? values
    }

    private func enforceRetention(
        accountID: String,
        projectID: String,
        now: Date
    ) throws {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let values = try records(accountID: accountID, projectID: projectID)
        for value in values where value.fetchedAt < cutoff { context.delete(value) }
        for value in values.filter({ $0.fetchedAt >= cutoff }).dropFirst(500) {
            context.delete(value)
        }
    }

    private static func protectedStoreDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "PrivateEventCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private static func validReference(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{22,200}$"#, options: .regularExpression) != nil
    }
}
