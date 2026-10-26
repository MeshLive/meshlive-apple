import XCTest
@testable import NearbyCore

/// Sealed local records: migration from plain text, the wipe latch, an unavailable or damaged key.
final class SealedRecordFilesTests: XCTestCase {
    final class Keys: SealedRecordKeyStore {
        var key: Data?, failRead = false, failAdd = false
        func readKey() throws -> Data? { if failRead { throw NSError(domain: "keychain", code: -25308) }; return key }
        func addKey(_ key: Data) throws {
            if failAdd { throw NSError(domain: "keychain", code: -25308) }
            if self.key != nil { throw SealedRecordKeyError.duplicate }
            self.key = key
        }
        func replaceKey(_ key: Data) throws { self.key = key }
    }

    private var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store(_ keys: Keys, latched: Bool = false) -> SealedRecordFiles {
        SealedRecordFiles(directory: dir, keys: keys, latched: { latched })
    }

    func testMigrationMovesThePlainCopyOnceAndPrefersAnExistingSealedRecord() throws {
        let keys = Keys(), files = store(keys)
        var legacy: Data? = Data("old list".utf8)
        files.migrate(legacy: legacy, name: "recent.bin", purpose: "p", removeLegacy: { legacy = nil })
        XCTAssertNil(legacy, "the plain copy is gone after the sealed write")
        XCTAssertEqual(files.read("recent.bin", purpose: "p"), .value(Data("old list".utf8)))
        let raw = try Data(contentsOf: files.url("recent.bin"))
        XCTAssertNil(raw.range(of: Data("old list".utf8)), "sealed at rest")

        files.write(Data("newer".utf8), name: "recent.bin", purpose: "p")
        var stale: Data? = Data("stale plain copy".utf8)
        files.migrate(legacy: stale, name: "recent.bin", purpose: "p", removeLegacy: { stale = nil })
        XCTAssertNil(stale)
        XCTAssertEqual(files.read("recent.bin", purpose: "p"), .value(Data("newer".utf8)), "the sealed record is never overwritten by legacy")
    }

    func testAnUnavailableKeyWritesNothingAndReadsAsUnreadableNotEmpty() {
        let keys = Keys(), files = store(keys)
        files.write(Data("pins".utf8), name: "pins.bin", purpose: "p")
        keys.failRead = true
        XCTAssertEqual(files.read("pins.bin", purpose: "p"), .unreadable("key"), "a locked Keychain is not an empty store")
        XCTAssertFalse(files.write(Data("x".utf8), name: "other.bin", purpose: "p"))
        XCTAssertEqual(files.read("other.bin", purpose: "p"), .absent, "no plain text instead")
    }

    func testAWrongLengthKeyIsReplacedWhenWriting() {
        let keys = Keys(); keys.key = Data(repeating: 1, count: 16)
        let files = store(keys)
        XCTAssertTrue(files.write(Data("calls".utf8), name: "recent.bin", purpose: "p"))
        XCTAssertEqual(keys.key?.count, 32)
        XCTAssertEqual(files.read("recent.bin", purpose: "p"), .value(Data("calls".utf8)))
    }

    func testAKeyAddedMeanwhileIsReadBack() {
        final class Racing: SealedRecordKeyStore {
            var key: Data?; var reads = 0
            func readKey() throws -> Data? { reads += 1; return reads == 1 ? nil : key }
            func addKey(_ key: Data) throws { self.key = Data(repeating: 7, count: 32); throw SealedRecordKeyError.duplicate }
            func replaceKey(_ key: Data) throws {}
        }
        let keys = Racing(), files = SealedRecordFiles(directory: dir, keys: keys, latched: { false })
        XCTAssertTrue(files.write(Data("a".utf8), name: "r.bin", purpose: "p"))
        XCTAssertEqual(files.read("r.bin", purpose: "p"), .value(Data("a".utf8)), "sealed under the key that won the race")
    }

    func testNothingIsWrittenOnceLatched() {
        let keys = Keys(), files = store(keys, latched: true)
        XCTAssertFalse(files.write(Data("late".utf8), name: "recent.bin", purpose: "p"))
        var legacy: Data? = Data("old".utf8)
        files.migrate(legacy: legacy, name: "recent.bin", purpose: "p", removeLegacy: { legacy = nil })
        XCTAssertEqual(files.read("recent.bin", purpose: "p"), .absent)
        XCTAssertNil(keys.key, "not even a key is created")
    }
}
