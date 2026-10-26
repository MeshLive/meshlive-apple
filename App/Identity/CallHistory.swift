import Foundation
import Security
import CryptoKit
import NearbyCore

/// Local recent-calls history (Android v7 Home "Recent calls"): the last 20 calls on this phone only, never
/// sent anywhere. Sealed at rest (`SealedRecords`, review 2026-10-27): the records name peers by ID prefix. Earlier
/// builds kept them in plain text in UserDefaults; that copy moves into the sealed file once. The emergency wipe
/// deletes both.
struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case outgoing, incoming, missed }
    var id = UUID()
    let prefixHex: String
    let direction: Direction
    let video: Bool
    let at: Date
    let seconds: Int
}

enum CallHistory {
    private static let legacyKey = "recentCalls"
    static let fileName = "recent-calls.bin"
    private static let purpose = "MeshLive/RecentCalls/1"
    static let limit = 20

    static var all: [CallRecord] {
        migrateLegacy()
        guard let data = SealedRecords.read(fileName, purpose: purpose),
              let list = try? JSONDecoder().decode([CallRecord].self, from: data) else { return [] }
        return list
    }

    static func add(_ record: CallRecord) {
        guard record.prefixHex.count == 12, let data = try? JSONEncoder().encode(Array(([record] + all).prefix(limit))) else { return }
        SealedRecords.write(data, name: fileName, purpose: purpose)
    }

    static func clear() {
        DesktopPreview.preferences.removeObject(forKey: legacyKey)
        SealedRecords.delete(fileName)
    }

    /// The plain-text list of earlier builds moves into the sealed file; it is removed only after the sealed write.
    private static func migrateLegacy() {
        guard let legacy = DesktopPreview.preferences.data(forKey: legacyKey) else { return }
        if SealedRecords.write(legacy, name: fileName, purpose: purpose) { DesktopPreview.preferences.removeObject(forKey: legacyKey) }
    }
}

/// Small local records sealed at rest (recent calls, BMH3 pins) under one this-device-only Keychain key that stays
/// readable after the first unlock (a call can arrive while the phone is locked). When the key cannot be read (a
/// locked Keychain, an error) nothing is read or written: never plain text instead. Nothing is written after an
/// emergency wipe in this run.
enum SealedRecords {
    static let account = "records-key"
    static var directory: URL { VerifiedContactsStore.url.deletingLastPathComponent() }

    private static func key(create: Bool) -> Data? {
        if DesktopPreview.enabled { return nil }
        do {
            if let existing = try KeychainItem.read(account) { return existing }
            guard create else { return nil }
            let created = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainItem.write(account, created, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            return created
        } catch {
            AppLog.event("storage", ["event": "records_key", "result": "unavailable"])
            return nil
        }
    }

    static func read(_ name: String, purpose: String) -> Data? {
        guard let blob = try? Data(contentsOf: directory.appendingPathComponent(name)), let key = key(create: false) else { return nil }
        return SealedBlob.open(blob, key: key, purpose: purpose)
    }

    @discardableResult
    static func write(_ plain: Data, name: String, purpose: String) -> Bool {
        guard !EmergencyWipe.happened, let key = key(create: true), let sealed = try? SealedBlob.seal(plain, key: key, purpose: purpose) else { return false }
        var dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BackupExclusion.apply(&dir)
        do {
            try sealed.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
}
