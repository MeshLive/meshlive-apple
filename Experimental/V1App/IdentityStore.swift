import Foundation
import Security
import CryptoKit
import NearbyCore

enum IdentityStore {
    static func load() throws -> Curve25519.KeyAgreement.PrivateKey {
        // The key moves once from the old service name; until that succeeds the old copy is still read.
        let store = SecKeychainServiceStore()
        _ = KeychainServiceMigration.run(from: KeychainServices.legacyV1Identity, to: KeychainServices.v1Identity, store: store)
        let found = KeychainServices.read("static-x25519", current: KeychainServices.v1Identity,
                                          legacy: KeychainServices.legacyV1Identity, store: store)
        if found.status == errSecSuccess, let data = found.item?.data { return try .init(rawRepresentation: data) }
        guard found.status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(found.status)) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: KeychainServices.v1Identity,
                                   kSecAttrAccount as String: "static-x25519"]
        let key = Curve25519.KeyAgreement.PrivateKey()
        var add = query; add[kSecValueData as String] = key.rawRepresentation
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(add as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        return key
    }
}
