import Foundation

/// Local recent-calls history (Android v7 Home "Recent calls"): the last 20 calls on this phone only, never
/// sent anywhere. Stored in this app's UserDefaults domain, which the emergency wipe removes entirely.
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
    private static let key = "recentCalls"
    static let limit = 20

    static var all: [CallRecord] {
        guard let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([CallRecord].self, from: data) else { return [] }
        return list
    }

    static func add(_ record: CallRecord) {
        guard record.prefixHex.count == 12 else { return }
        let list = Array(([record] + all).prefix(limit))
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
