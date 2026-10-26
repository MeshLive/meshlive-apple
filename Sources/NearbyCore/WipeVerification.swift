import Foundation

/// When an emergency wipe may call itself finished: every Keychain deletion succeeded or found nothing, a verification
/// query then reported "not found" for everything (an error is not absence: a locked Keychain proves nothing), and no
/// listed file is left. Until then the app keeps its wipe marker and resumes the wipe at the next launch.
public enum WipeVerification {
    /// A deletion counts when it removed the items or there were none (`errSecSuccess`, `errSecItemNotFound`).
    public static func deleted(_ status: Int32) -> Bool { status == KeychainReplace.success || status == KeychainReplace.itemNotFound }

    /// Only `errSecItemNotFound` confirms absence; success (something is still there) or any error does not.
    public static func confirmedAbsent(_ status: Int32) -> Bool { status == KeychainReplace.itemNotFound }

    public static func complete(deletions: [Int32], verifications: [Int32], filesLeft: Int) -> Bool {
        !verifications.isEmpty && deletions.allSatisfy(deleted) && verifications.allSatisfy(confirmedAbsent) && filesLeft == 0
    }
}
