import Foundation

/// How a stored secret (a Keychain item) is replaced without a moment where neither the old nor the new copy exists:
/// update the item in place, and add one only when none exists. Deleting first and then adding loses the old value
/// whenever the add fails (a locked device, a full Keychain), which for the presence vault would bring back an empty
/// vault. The closures return `OSStatus` values.
public enum KeychainReplace {
    public static let success: Int32 = 0
    public static let itemNotFound: Int32 = -25300   // errSecItemNotFound
    public static let duplicateItem: Int32 = -25299  // errSecDuplicateItem

    public static func write(update: () -> Int32, add: () -> Int32) -> Int32 {
        let updated = update()
        guard updated == itemNotFound else { return updated }
        let added = add()
        // Another writer added the item between the two calls: update that one.
        return added == duplicateItem ? update() : added
    }
}
