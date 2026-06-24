import Foundation
import Testing
@testable import GuessWhoSync

@Suite("ContactSyncCursorStore")
struct ContactSyncCursorStoreTests {
    /// Makes a unique temp directory and returns a cursor file URL inside it.
    private func makeTempCursorURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-cursor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contacts-change-cursor")
    }

    @Test
    func missingFileLoadsNil() throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ContactSyncCursorStore(url: url)
        #expect(store.load() == nil)
    }

    @Test
    func writeReadRoundTrip() throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ContactSyncCursorStore(url: url)
        let token = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try store.save(token)

        #expect(store.load() == token)
    }

    @Test
    func saveOverwritesPriorValue() throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ContactSyncCursorStore(url: url)
        try store.save(Data([0x01]))
        try store.save(Data([0x02, 0x03]))

        #expect(store.load() == Data([0x02, 0x03]))
    }

    @Test
    func savedFileIsExcludedFromBackup() throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ContactSyncCursorStore(url: url)
        try store.save(Data([0x42]))

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test
    func saveCreatesMissingParentDirectory() throws {
        // A nested path whose parent does not exist yet must be created on save.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-cursor-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let url = dir.appendingPathComponent("contacts-change-cursor")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let store = ContactSyncCursorStore(url: url)
        try store.save(Data([0x99]))

        #expect(store.load() == Data([0x99]))
    }
}
