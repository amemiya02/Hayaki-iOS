import Foundation
import Security

/// The learner's sign-in to one sync destination.
public struct SyncAccount: Codable, Equatable, Sendable {
    /// The configured self-hosted address. Nil selects the core's AnkiWeb default.
    public let server: URL?
    public let userName: String
    /// The key the server issued at sign-in (Anki calls it the host key). It
    /// authorises syncing without the password.
    public let hostKey: String
    /// A redirect returned by the core for this sign-in. Keep it separate
    /// from the configured address so it does not change the destination.
    var redirectedEndpoint: URL?
    var customCertificate: String?
    var mediaSync: SavedMediaSync?
    /// When a collection sync with this sign-in last finished.
    var lastCollectionSync: Date?
    /// When a media sync with this sign-in last finished.
    var lastMediaSync: Date?

    public init(server: URL?, userName: String, hostKey: String) {
        self.server = server
        self.userName = userName
        self.hostKey = hostKey
    }

    // The required server key is either a self-hosted URL (including legacy
    // items) or explicit null for AnkiWeb. A missing key indicates invalid data.
    private enum CodingKeys: String, CodingKey {
        case server, userName, hostKey, redirectedEndpoint, mediaSync, customCertificate
        case lastCollectionSync, lastMediaSync
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        server = try values.decode(URL?.self, forKey: .server)
        userName = try values.decode(String.self, forKey: .userName)
        hostKey = try values.decode(String.self, forKey: .hostKey)
        redirectedEndpoint = try values.decodeIfPresent(URL.self, forKey: .redirectedEndpoint)
        customCertificate = try values.decodeIfPresent(String.self, forKey: .customCertificate)
        mediaSync = try values.decodeIfPresent(SavedMediaSync.self, forKey: .mediaSync)
        lastCollectionSync = try values.decodeIfPresent(Date.self, forKey: .lastCollectionSync)
        lastMediaSync = try values.decodeIfPresent(Date.self, forKey: .lastMediaSync)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(server, forKey: .server)
        try values.encode(userName, forKey: .userName)
        try values.encode(hostKey, forKey: .hostKey)
        try values.encodeIfPresent(redirectedEndpoint, forKey: .redirectedEndpoint)
        try values.encodeIfPresent(customCertificate, forKey: .customCertificate)
        try values.encodeIfPresent(mediaSync, forKey: .mediaSync)
        try values.encodeIfPresent(lastCollectionSync, forKey: .lastCollectionSync)
        try values.encodeIfPresent(lastMediaSync, forKey: .lastMediaSync)
    }
}

/// Where the sync account is kept between launches. The app uses
/// `KeychainSyncAccountStorage`; tests on the Mac substitute their own, the
/// Keychain being a system boundary.
public protocol SyncAccountStorage: Sendable {
    /// The stored account, or nil when the learner is not signed in.
    func load() throws -> SyncAccount?
    func save(_ account: SyncAccount) throws
    /// Forgets the account, including its host key. Succeeds when there is none.
    func remove() throws
}

/// Keeps the sync account, host key included, as one generic password item in
/// the Keychain, never migrated to another device by a backup. It is readable
/// from the first unlock after a restart, so a sync that continues after the
/// screen locks or the app moves to the background can still read and update
/// it.
public struct KeychainSyncAccountStorage: SyncAccountStorage {
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    private let service: String
    private let account = "sync-account"

    public init(service: String = "io.github.amemiya02.hayaki.sync", profileID: UUID? = nil) {
        self.service = profileID.map { "\(service).\($0.uuidString)" } ?? service
    }

    public func load() throws -> SyncAccount? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data
        else { throw KeychainError(status: status) }
        // Earlier builds saved the item readable only while unlocked. The
        // first load, which runs while the app is in use, moves it over.
        if attributes[kSecAttrAccessible as String] as? String != Self.accessibility as String {
            let update = [kSecAttrAccessible as String: Self.accessibility]
            _ = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        }
        return try JSONDecoder().decode(SyncAccount.self, from: data)
    }

    public func save(_ account: SyncAccount) throws {
        let data = try JSONEncoder().encode(account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = Self.accessibility
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// A Keychain call failed.
public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return String(localized: "The device's secure storage reported an error: \(detail)", bundle: .module)
    }
}
