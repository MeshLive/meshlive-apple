import Foundation
import CryptoKit

/// Small local records sealed at rest with AES-GCM (as Android): recent calls and BMH3
/// pins name peers by ID prefix, so they are not kept in plain text. The key is a this-device-only Keychain item;
/// `purpose` is bound as associated data, so a blob of one store never opens as another. A blob that does not open
/// (wrong key, damaged, another purpose) reads as absent, never as a crash.
public enum SealedBlob {
    public static func seal(_ plain: Data, key: Data, purpose: String) throws -> Data {
        guard key.count == 32 else { throw ProtocolError.malformed("Sealing key must be 32 bytes") }
        guard let combined = try AES.GCM.seal(plain, using: SymmetricKey(data: key), authenticating: Data(purpose.utf8)).combined else {
            throw ProtocolError.malformed("Sealing failed")
        }
        return combined
    }

    public static func open(_ sealed: Data, key: Data, purpose: String) -> Data? {
        guard key.count == 32, let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(purpose.utf8))
    }
}
