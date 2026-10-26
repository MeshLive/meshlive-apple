import Foundation
import CryptoKit

/// The key of the sealed local records, kept by the platform (the app: a this-device-only Keychain item).
public protocol SealedRecordKeyStore {
    /// nil when no key exists yet; throws when it cannot be read (an error is never absence).
    func readKey() throws -> Data?
    /// Adds the key only when none exists; throws `duplicate` when one appeared meanwhile.
    func addKey(_ key: Data) throws
    /// Replaces a damaged key (wrong length).
    func replaceKey(_ key: Data) throws
}

public enum SealedRecordKeyError: Error { case duplicate }

/// What a sealed record read found: nothing stored, the record, or something that exists but cannot be opened.
public enum SealedRead: Equatable {
    case absent
    case value(Data)
    case unreadable(String)
}

/// Small local records sealed at rest (recent calls, BMH3 pins; review 2026-10-27): AES-GCM blobs (`SealedBlob`) in
/// one directory under one key. When the key cannot be read nothing is written, never plain text instead; a blob that
/// does not open reads as `unreadable` (callers must not overwrite it as if it were empty). Nothing is written once
/// `latched` (after an emergency wipe in this run).
public final class SealedRecordFiles {
    public let directory: URL
    private let keys: SealedRecordKeyStore
    private let latched: () -> Bool
    private let log: (String) -> Void
    private let fileProtection: Data.WritingOptions

    public init(directory: URL, keys: SealedRecordKeyStore, latched: @escaping () -> Bool, log: @escaping (String) -> Void = { _ in },
                fileProtection: Data.WritingOptions = []) {
        self.directory = directory; self.keys = keys; self.latched = latched; self.log = log; self.fileProtection = fileProtection
    }

    private func key(create: Bool) -> Data? {
        do {
            if let existing = try keys.readKey() {
                if existing.count == 32 { return existing }
                // A damaged key can never open or seal anything: replace it when writing; records under it are lost.
                log("event=records_key | result=wrong_length | bytes=\(existing.count)")
                guard create else { return nil }
                let fresh = Self.newKey()
                try keys.replaceKey(fresh)
                return fresh
            }
            guard create else { return nil }
            let fresh = Self.newKey()
            do { try keys.addKey(fresh); return fresh }
            catch SealedRecordKeyError.duplicate { return try keys.readKey().flatMap { $0.count == 32 ? $0 : nil } }
        } catch {
            log("event=records_key | result=unavailable")
            return nil
        }
    }

    private static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read(_ name: String, purpose: String) -> SealedRead {
        guard FileManager.default.fileExists(atPath: url(name).path) else { return .absent }
        guard let blob = try? Data(contentsOf: url(name)) else { return .unreadable("file") }
        guard let key = key(create: false) else { return .unreadable("key") }
        guard let plain = SealedBlob.open(blob, key: key, purpose: purpose) else { return .unreadable("open") }
        return .value(plain)
    }

    @discardableResult
    public func write(_ plain: Data, name: String, purpose: String) -> Bool {
        guard !latched(), let key = key(create: true), let sealed = try? SealedBlob.seal(plain, key: key, purpose: purpose) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try sealed.write(to: url(name), options: fileProtection.union(.atomic)); return true } catch { return false }
    }

    public func delete(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    /// One-time move of a plain-text copy kept by earlier builds. An existing sealed record wins (the legacy copy is
    /// only deleted); otherwise the legacy bytes are sealed and the legacy copy is removed after the sealed write.
    public func migrate(legacy: Data?, name: String, purpose: String, removeLegacy: () -> Void) {
        guard let legacy, !latched() else { return }
        switch read(name, purpose: purpose) {
        case .value, .unreadable:
            removeLegacy(); log("event=migrate | record=\(name) | result=sealed_exists")
        case .absent:
            if write(legacy, name: name, purpose: purpose) { removeLegacy(); log("event=migrate | record=\(name) | result=moved") }
        }
    }
}
