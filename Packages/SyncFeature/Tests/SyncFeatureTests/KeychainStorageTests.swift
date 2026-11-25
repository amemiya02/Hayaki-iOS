import Foundation
import Security
import SyncFeature
import Testing

/// Whether this process may write to the data protection Keychain. An
/// unsigned test run on the Mac may not.
private let keychainIsAvailable: Bool = {
    let probe: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.amemiya02.hayaki.sync.tests.probe",
        kSecAttrAccount as String: "probe",
        kSecUseDataProtectionKeychain as String: true,
        kSecValueData as String: Data([1]),
    ]
    let status = SecItemAdd(probe as CFDictionary, nil)
    SecItemDelete(probe as CFDictionary)
    return status == errSecSuccess || status == errSecDuplicateItem
}()

/// The sign-in must stay readable after the screen locks, because a sync
/// finishes in the background. Skipped where the process has no Keychain.
@Suite("The Keychain item of the sign-in", .serialized, .enabled(if: keychainIsAvailable))
struct KeychainStorageTests {
    private let service = "io.github.amemiya02.hayaki.sync.tests.\(UUID().uuidString)"
    private let account = SyncAccount(server: nil, userName: "alice", hostKey: "key")

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sync-account",
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func accessibility() -> String? {
        var item: CFTypeRef?
        var query = query
        query[kSecReturnAttributes as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    @Test("A saved sign-in is readable from the first unlock")
    func savedItemSurvivesTheLock() throws {
        let storage = KeychainSyncAccountStorage(service: service)
        defer { try? storage.remove() }

        try storage.save(account)

        #expect(accessibility() == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(try storage.load() == account)
    }

    @Test("Loading moves a sign-in saved by an earlier build")
    func loadMigratesAnUnlockedOnlyItem() throws {
        let storage = KeychainSyncAccountStorage(service: service)
        defer { try? storage.remove() }
        var old = query
        old[kSecValueData as String] = try JSONEncoder().encode(account)
        old[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #expect(SecItemAdd(old as CFDictionary, nil) == errSecSuccess)

        #expect(try storage.load() == account)

        #expect(accessibility() == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
