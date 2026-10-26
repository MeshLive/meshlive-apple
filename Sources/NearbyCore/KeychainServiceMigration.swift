import Foundation
import Security

/// One generic-password item as the migration sees it: the secret and its protection class (`kSecAttrAccessible`),
/// which is carried over unchanged. `accessible` is nil where the platform reports none.
public struct KeychainStoredItem: Equatable {
    public var data: Data
    public var accessible: String?
    public init(data: Data, accessible: String? = nil) { self.data = data; self.accessible = accessible }
}

/// The Keychain operations the service rename needs. Statuses are `OSStatus` values (`KeychainReplace` constants);
/// `itemNotFound` is the only status that means absence, every other failure is an error.
public protocol KeychainServiceStore {
    /// The accounts stored under `service`.
    func accounts(service: String) -> (status: Int32, accounts: [String])
    func read(service: String, account: String) -> (status: Int32, item: KeychainStoredItem?)
    func add(service: String, account: String, item: KeychainStoredItem) -> Int32
    func delete(service: String, account: String) -> Int32
    /// Deletes every item of `service`.
    func deleteAll(service: String) -> Int32
}

/// The Keychain service names. The app was first developed as "Nearby Intercom" and stored its items under
/// `org.nearbyintercom.*`; current builds use `io.github.meshlive.app.*` and move existing items once
/// (`KeychainServiceMigration`). The emergency wipe deletes and verifies every name, old and new.
public enum KeychainServices {
    /// Identity, contacts key, presence vault and its guard secret.
    public static let current = "io.github.meshlive.app.mesh.v2"
    public static let legacyCurrent = "org.nearbyintercom.mesh.v2"
    /// The phase 1 rotating-ID presence key, replaced by the presence vault: only ever deleted, never moved.
    public static let legacyPresence = "org.nearbyintercom.rotating"
    /// The retained, default-off v1 experiment app's static key.
    public static let v1Identity = "io.github.meshlive.app.identity.v1"
    public static let legacyV1Identity = "org.nearbyintercom.identity.v1"

    /// Every service any version of the app used; the emergency wipe deletes and verifies each one.
    public static let all = [current, legacyCurrent, legacyPresence, v1Identity, legacyV1Identity]

    /// Reads `account` from the current service, or from the old one while its migration is unfinished (everything
    /// written since the rename goes to the current service, so the current copy wins). An error is returned as an
    /// error, never as absence, so a caller cannot mistake a locked Keychain for a missing identity.
    public static func read(_ account: String, current: String = KeychainServices.current, legacy: String = KeychainServices.legacyCurrent,
                            store: KeychainServiceStore) -> (status: Int32, item: KeychainStoredItem?) {
        let now = store.read(service: current, account: account)
        guard now.status == KeychainReplace.itemNotFound else { return now }
        return store.read(service: legacy, account: account)
    }

    /// Deletes `account` under both names, so an unfinished migration cannot bring a deleted secret back.
    /// Returns the first failure, or success (absence counts as deleted).
    public static func delete(_ account: String, current: String = KeychainServices.current, legacy: String = KeychainServices.legacyCurrent,
                              store: KeychainServiceStore) -> Int32 {
        let statuses = [store.delete(service: current, account: account), store.delete(service: legacy, account: account)]
        return statuses.first { !WipeVerification.deleted($0) } ?? KeychainReplace.success
    }

    /// The wipe's deletions: one status per service in `all`.
    public static func deleteAll(store: KeychainServiceStore) -> [Int32] { all.map { store.deleteAll(service: $0) } }

    /// The wipe's verification: one query per service; only `itemNotFound` confirms that nothing is left.
    public static func verifyAllDeleted(store: KeychainServiceStore) -> [Int32] { all.map { store.accounts(service: $0).status } }
}

/// Moves Keychain items from an old service name to a new one without ever risking the identity: per account, copy
/// to the new service (unless it already holds that account, which then wins), read the copy back, and only when it
/// matches delete the old item. A failure leaves that old item in place: the app keeps reading it through
/// `KeychainServices.read` and the next launch retries. Running it again is harmless, so a crash between the copy and
/// the delete is finished by the next run.
public enum KeychainServiceMigration {
    public struct Result: Equatable {
        /// Accounts now only under the new service.
        public var moved = 0
        /// Accounts still under the old service (an error); retried at the next launch.
        public var pending = 0
        /// The old service could not be listed (an error, not absence).
        public var listFailed = false
        public var complete: Bool { !listFailed && pending == 0 }
        public init(moved: Int = 0, pending: Int = 0, listFailed: Bool = false) {
            self.moved = moved; self.pending = pending; self.listFailed = listFailed
        }
    }

    public static func run(from old: String, to new: String, store: KeychainServiceStore) -> Result {
        var result = Result()
        let listing = store.accounts(service: old)
        if listing.status == KeychainReplace.itemNotFound { return result }
        guard listing.status == KeychainReplace.success else { result.listFailed = true; return result }
        for account in Set(listing.accounts).sorted() {
            if move(account, from: old, to: new, store: store) { result.moved += 1 } else { result.pending += 1 }
        }
        return result
    }

    /// True when `account` no longer exists under `old` and the new service holds its value.
    private static func move(_ account: String, from old: String, to new: String, store: KeychainServiceStore) -> Bool {
        let source = store.read(service: old, account: account)
        if source.status == KeychainReplace.itemNotFound { return true }
        guard source.status == KeychainReplace.success, let item = source.item else { return false }
        let target = store.read(service: new, account: account)
        if target.status == KeychainReplace.itemNotFound {
            let added = store.add(service: new, account: account, item: item)
            if added == KeychainReplace.success {
                let copy = store.read(service: new, account: account)
                guard copy.status == KeychainReplace.success, let copied = copy.item else { return false }
                guard copied.data == item.data else {
                    // A copy that reads back differently would win over the good old item: remove it, keep the old.
                    _ = store.delete(service: new, account: account)
                    return false
                }
            } else if added != KeychainReplace.duplicateItem {
                return false
            }
            // duplicateItem: another writer stored the account under the new name meanwhile; that newer value wins.
        } else if target.status != KeychainReplace.success || target.item == nil {
            return false
        }
        return WipeVerification.deleted(store.delete(service: old, account: account))
    }
}

/// `KeychainServiceStore` on the real Keychain (generic-password items).
public struct SecKeychainServiceStore: KeychainServiceStore {
    public init() {}

    private func base(_ service: String, _ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func accounts(service: String) -> (status: Int32, accounts: [String]) {
        var query = base(service)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, []) }
        let rows = (result as? [[String: Any]]) ?? []
        return (status, rows.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    public func read(service: String, account: String) -> (status: Int32, item: KeychainStoredItem?) {
        var query = base(service, account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let row = result as? [String: Any], let data = row[kSecValueData as String] as? Data else {
            return (errSecDecode, nil)
        }
        return (status, KeychainStoredItem(data: data, accessible: row[kSecAttrAccessible as String] as? String))
    }

    public func add(service: String, account: String, item: KeychainStoredItem) -> Int32 {
        var query = base(service, account)
        query[kSecValueData as String] = item.data
        if let accessible = item.accessible { query[kSecAttrAccessible as String] = accessible }
        return SecItemAdd(query as CFDictionary, nil)
    }

    public func delete(service: String, account: String) -> Int32 { SecItemDelete(base(service, account) as CFDictionary) }

    public func deleteAll(service: String) -> Int32 {
        let first = SecItemDelete(base(service) as CFDictionary)
        #if os(macOS)
        // The file-based macOS Keychain can remove one match per call: repeat until nothing matches.
        var status = first, rounds = 0
        while status == errSecSuccess && rounds < 64 { status = SecItemDelete(base(service) as CFDictionary); rounds += 1 }
        if first == errSecSuccess && status != errSecItemNotFound { return status }
        #endif
        return first
    }
}
