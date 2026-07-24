// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Security

struct KeychainStore {
    private let service = AppConfig.keychainService
    private let account = "auth-session"
    private let installationAccount = "installation-id"
    private let legacyDirectKeyIDAccount = "direct-key-id-v1"
    private let legacyDirectAgreementKeyAccount = "direct-agreement-private-v1"
    private let legacyDirectSigningKeyAccount = "direct-signing-private-v1"
    private let sharedDirectContextAccount = "notification-context-v1"

    func save(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func read() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    func installationID() throws -> String {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: installationAccount
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           UUID(uuidString: value) != nil {
            return value.lowercased()
        }

        let value = UUID().uuidString.lowercased()
        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(base as CFDictionary)
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return value
    }

    func deviceIdentity(userID: String) throws -> DeviceIdentity {
        let directKeyIDAccount = directAccount("key-id", userID: userID)
        let directAgreementKeyAccount = directAccount("agreement-private", userID: userID)
        let directSigningKeyAccount = directAccount("signing-private", userID: userID)
        let keyID: String
        if let data = readDirectData(account: directKeyIDAccount),
           let savedID = String(data: data, encoding: .utf8),
           UUID(uuidString: savedID) != nil {
            keyID = savedID.lowercased()
        } else {
            keyID = UUID().uuidString.lowercased()
            try saveDirectData(Data(keyID.utf8), account: directKeyIDAccount)
        }

        let agreementKey: P256.KeyAgreement.PrivateKey
        if let data = readDirectData(account: directAgreementKeyAccount),
           let savedKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) {
            agreementKey = savedKey
        } else {
            agreementKey = P256.KeyAgreement.PrivateKey()
            try saveDirectData(agreementKey.rawRepresentation, account: directAgreementKeyAccount)
        }

        let signingKey: P256.Signing.PrivateKey
        if let data = readDirectData(account: directSigningKeyAccount),
           let savedKey = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            signingKey = savedKey
        } else {
            signingKey = P256.Signing.PrivateKey()
            try saveDirectData(signingKey.rawRepresentation, account: directSigningKeyAccount)
        }

        deleteData(account: legacyDirectKeyIDAccount)
        deleteData(account: legacyDirectAgreementKeyAccount)
        deleteData(account: legacyDirectSigningKeyAccount)
        return DeviceIdentity(id: keyID, agreementKey: agreementKey, signingKey: signingKey)
    }

    func saveDirectConnectionManifests(
        _ manifests: [DirectConnectionManifest],
        userID: String
    ) throws {
        try saveDirectData(
            JSONEncoder().encode(manifests),
            account: "direct-connections-\(userID)"
        )
    }

    func directConnectionManifests(userID: String) -> [DirectConnectionManifest] {
        guard let data = readDirectData(account: "direct-connections-\(userID)") else { return [] }
        return (try? JSONDecoder().decode([DirectConnectionManifest].self, from: data)) ?? []
    }

    @discardableResult
    func deleteDirectConnection(projectID: String, userID: String) throws -> Bool {
        var manifests = directConnectionManifests(userID: userID)
        let originalCount = manifests.count
        manifests.removeAll { $0.project.id == projectID }
        guard manifests.count != originalCount else { return false }
        try saveDirectConnectionManifests(manifests, userID: userID)
        return true
    }

    func deleteDirectData(userID: String) {
        deleteDirectData(account: "direct-connections-\(userID)")
        deleteDirectData(account: directAccount("key-id", userID: userID))
        deleteDirectData(account: directAccount("agreement-private", userID: userID))
        deleteDirectData(account: directAccount("signing-private", userID: userID))
        deleteDirectData(account: sharedDirectContextAccount)
    }

    func deleteDirectNotificationContext() {
        deleteDirectData(account: sharedDirectContextAccount)
    }

    func saveDirectNotificationContext(
        manifests: [DirectConnectionManifest],
        identity: DeviceIdentity
    ) throws {
        let context = SharedDirectNotificationContext(
            keyID: identity.id,
            signingPrivateKey: identity.signingKey.rawRepresentation.base64EncodedString(),
            manifests: manifests
        )
        try saveDirectData(
            JSONEncoder().encode(context),
            account: sharedDirectContextAccount
        )
    }

    private func directAccount(_ component: String, userID: String) -> String {
        "direct-\(component)-v2-\(userID.lowercased())"
    }

    private func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func readDirectData(account: String) -> Data? {
        if let shared = readData(
            account: account,
            service: AppConfig.sharedDirectKeychainService,
            accessGroup: AppConfig.keychainAccessGroup
        ) {
            return shared
        }
        guard let legacy = readData(account: account) else { return nil }
        try? saveDirectData(legacy, account: account)
        deleteData(account: account)
        return legacy
    }

    private func saveData(_ data: Data, account: String) throws {
        try saveData(data, account: account, service: service, accessGroup: nil)
    }

    private func saveDirectData(_ data: Data, account: String) throws {
        try saveData(
            data,
            account: account,
            service: AppConfig.sharedDirectKeychainService,
            accessGroup: AppConfig.keychainAccessGroup
        )
    }

    private func saveData(
        _ data: Data,
        account: String,
        service selectedService: String,
        accessGroup: String?
    ) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: selectedService,
            kSecAttrAccount as String: account
        ].merging(accessGroup.map { [kSecAttrAccessGroup as String: $0] } ?? [:]) { current, _ in current }
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func deleteData(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    private func deleteDirectData(account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.sharedDirectKeychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppConfig.keychainAccessGroup
        ]
        SecItemDelete(query as CFDictionary)
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        query[kSecAttrService as String] = service
        SecItemDelete(query as CFDictionary)
    }

    private func readData(
        account: String,
        service selectedService: String,
        accessGroup: String?
    ) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: selectedService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }
}

private struct SharedDirectNotificationContext: Codable {
    let keyID: String
    let signingPrivateKey: String
    let manifests: [DirectConnectionManifest]
}

struct DeviceIdentity {
    let id: String
    let agreementKey: P256.KeyAgreement.PrivateKey
    let signingKey: P256.Signing.PrivateKey

    func descriptor(installationID: String) -> DeviceKeyDescriptor {
        DeviceKeyDescriptor(
            id: id,
            installationId: installationID,
            agreementPublicKey: agreementKey.publicKey.x963Representation.base64EncodedString(),
            signingPublicKey: signingKey.publicKey.x963Representation.base64EncodedString(),
            algorithm: "p256"
        )
    }

    func decrypt(_ envelope: DirectConnectionEnvelopeRecord) throws -> Data {
        guard envelope.algorithm == "p256-hkdf-sha256-aes-gcm",
              let ephemeralData = Data(base64Encoded: envelope.ephemeralPublicKey),
              let sealedData = Data(base64Encoded: envelope.sealedBox)
        else { throw DirectConnectionError.invalidEnvelope }
        let ephemeralKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
        let secret = try agreementKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(id.utf8),
            sharedInfo: Data("bellwire-direct-connection-v1".utf8),
            outputByteCount: 32
        )
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealedData), using: key)
    }

    func signature(for canonicalRequest: Data) throws -> String {
        try signingKey.signature(for: canonicalRequest)
            .rawRepresentation
            .base64EncodedString()
    }
}

struct DeviceKeyDescriptor: Encodable {
    let id: String
    let installationId: String
    let agreementPublicKey: String
    let signingPublicKey: String
    let algorithm: String
}

enum DirectConnectionError: Error {
    case invalidEnvelope
    case invalidManifest
    case invalidResponse
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not securely save the session (\(status))." }
}
