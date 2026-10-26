import Foundation

/// "You appear as mild bream · changes every 15 min" (Android OwnNearbyName): what a nearby device that has not added
/// you shows for this device right now, so two people meeting can match up. Shown on Calls › Nearby, under
/// Settings › Your name while no name is set, on the incoming call screen and on Add contact.
///
/// The name is the generated name of this device's current rotating call ID (the value a scanner computes from the same
/// public bytes), so it changes at every rotating-ID boundary. With rotating IDs off, people who have not added you see
/// "Someone nearby", which does not change; with generated names off, rotating rows read "Nearby phone".
public enum OwnNearbyName {
    public struct Shown: Equatable {
        public let name: String
        public let rotates: Bool
        public init(name: String, rotates: Bool) { self.name = name; self.rotates = rotates }
    }

    public static let someoneNearby = "Someone nearby"
    public static let nearbyPhone = "Nearby phone"
    public static let infoTitle = "Your name nearby"
    public static let info = "To keep you private, your device shows people nearby a random ID that changes every 15 minutes, and they see a made-up name made from it. Your real name, if you set one, is only sent encrypted to the people you choose (Settings › Your name)."

    /// nil while this device is not reachable for calls, or before its rotating ID with a generated name is on air.
    public static func shown(reachableForCalls: Bool, rotatingOn: Bool, generatedNamesOn: Bool, generatedName: String?) -> Shown? {
        guard reachableForCalls else { return nil }
        if !rotatingOn { return Shown(name: someoneNearby, rotates: false) }
        if !generatedNamesOn { return Shown(name: nearbyPhone, rotates: false) }
        return generatedName.map { Shown(name: $0, rotates: true) }
    }

    public static func line(_ shown: Shown) -> String {
        shown.rotates ? "You appear as \(shown.name) \u{00B7} changes every 15 min" : "You appear as \(shown.name)"
    }
}
