import Foundation
import CryptoKit
import NearbyCore

/// Android names-v2. Only a public rotating advert or an authenticated throwaway session can be named.
/// Generated words are a display aid, never an identity or a contact-verification decision.
struct DesktopNearbyNames {
    struct Name: Equatable {
        let text: String
        let number: Int
        let idTail: String
        let chip: Int
        var numbered: String { String(format: "%@ %02d", text, number) }
    }

    static let shared: DesktopNearbyNames? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        func bytes(_ name: String) -> Data? {
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "Names").flatMap { try? Data(contentsOf: $0) }
        }
        guard let a = bytes("adjectives-v2"), let n = bytes("nouns-v2"), let b = bytes("blocked-pairs-v2") else { return nil }
        return DesktopNearbyNames(adjectives: a, nouns: n, blockedPairs: b)
    }()

    private let adjectives: [String]
    private let nouns: [String]
    private let blocked: Set<String>

    init?(adjectives: Data, nouns: Data, blockedPairs: Data) {
        let hashes = ["d832789668051db146496979eaf9d362b90f43c55d51febb9c825dc1e0417b46",
                      "1560dd97fdb19313fcdcfd6335c454d888d298ca2da595fc4c032d051ab4a39c",
                      "381d7404fe637a61ace734d6569103f159de2e27d2ea62adc54dae4f9acfa304"]
        for (data, hash) in zip([adjectives, nouns, blockedPairs], hashes) {
            guard Data(SHA256.hash(data: data)).hex == hash else { return nil }
        }
        func lines(_ data: Data) -> [String] { String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) }
        self.adjectives = lines(adjectives); self.nouns = lines(nouns); blocked = Set(lines(blockedPairs))
        guard self.adjectives.count == 256, self.nouns.count == 256 else { return nil }
    }

    func name(for announcement: DiscoveryAnnouncement) -> Name? {
        guard announcement.rotating, announcement.nodeIdPrefix.count == 6 else { return nil }
        return derive(announcement.nodeIdPrefix)
    }

    func name(forStranger engine: CallEngine) -> Name? {
        guard engine.peerIsStranger, let throwaway = engine.endpoint?.peerNodeId.bytes else { return nil }
        return derive(throwaway)
    }

    private func derive(_ bytes: Data) -> Name {
        for attempt in 0...16 {
            var input = Data("BluetoothVideoMesh/Naming/StrangerName/1".utf8)
            input.append(0); input.append(bytes)
            if attempt > 0 { input.append(UInt8(attempt)) }
            let d = Array(SHA256.hash(data: input))
            let text = "\(adjectives[Int(d[0])]) \(nouns[Int(d[1])])"
            if !blocked.contains(text) || attempt == 16 {
                return Name(text: text, number: Int(d[3]) % 100, idTail: bytes.suffix(2).hex, chip: Int(d[2]) & 7)
            }
        }
        preconditionFailure("Bounded name derivation must return")
    }

    /// Every member of a collision gets the same deterministic suffix rule, independent of scan order.
    static func labels(_ names: [Data: Name]) -> [Data: String] {
        var result: [Data: String] = [:]
        for group in Dictionary(grouping: names.keys, by: { names[$0]!.text }).values {
            if group.count == 1 { result[group[0]] = names[group[0]]!.text; continue }
            for numbered in Dictionary(grouping: group, by: { names[$0]!.numbered }).values {
                for id in numbered {
                    let name = names[id]!
                    result[id] = numbered.count == 1 ? name.numbered : "\(name.numbered)-\(name.idTail)"
                }
            }
        }
        return result
    }

    func labels(for announcements: [DiscoveryAnnouncement]) -> [Data: String] {
        var names: [Data: Name] = [:]
        for announcement in announcements { if let name = name(for: announcement) { names[announcement.nodeIdPrefix] = name } }
        return Self.labels(names)
    }
}
