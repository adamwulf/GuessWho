import Foundation
import Testing
@testable import GuessWhoSync

@Suite("DeviceIDStore")
struct DeviceIDStoreTests {
    /// Makes a unique temp directory and returns a device-id file URL inside it.
    private func makeTempDeviceIDURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-deviceid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("device-id")
    }

    /// True when `value` is a canonical (lowercased) UUID string.
    private func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    @Test
    func mintsCanonicalLowercaseUUID() throws {
        let url = try makeTempDeviceIDURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = DeviceIDStore(url: url).stableDeviceID()
        #expect(isCanonicalUUID(id))
    }

    @Test
    func reusesSameIDAcrossCallsAndInstances() throws {
        let url = try makeTempDeviceIDURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Same instance is stable...
        let store = DeviceIDStore(url: url)
        let first = store.stableDeviceID()
        #expect(store.stableDeviceID() == first)

        // ...and a fresh instance over the same path reads the persisted value
        // rather than minting a new one.
        let reopened = DeviceIDStore(url: url).stableDeviceID()
        #expect(reopened == first)
    }

    @Test
    func canonicalizesStoredUppercaseUUID() throws {
        let url = try makeTempDeviceIDURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // A valid-but-uppercase stored value is reused (device keeps identity),
        // returned in canonical lowercase form.
        let uuid = UUID()
        let uppercased = uuid.uuidString.uppercased()
        try Data(uppercased.utf8).write(to: url, options: .atomic)

        let id = DeviceIDStore(url: url).stableDeviceID()
        #expect(id == uuid.uuidString.lowercased())
        #expect(isCanonicalUUID(id))

        // The file has converged to the canonical form on disk.
        let onDisk = try String(data: Data(contentsOf: url), encoding: .utf8)
        #expect(onDisk == uuid.uuidString.lowercased())
    }

    @Test
    func regeneratesWhenFileIsInvalid() throws {
        let url = try makeTempDeviceIDURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Data("not-a-uuid".utf8).write(to: url, options: .atomic)

        let store = DeviceIDStore(url: url)
        let id = store.stableDeviceID()
        #expect(isCanonicalUUID(id))
        #expect(id != "not-a-uuid")

        // The regenerated id is now the persisted, stable value.
        #expect(store.stableDeviceID() == id)
        #expect(DeviceIDStore(url: url).stableDeviceID() == id)
    }

    @Test
    func regeneratesWhenFileHasTrailingGarbage() throws {
        let url = try makeTempDeviceIDURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // A UUID prefix followed by garbage does not parse as a UUID -> mint.
        try Data("\(UUID().uuidString)-extra".utf8).write(to: url, options: .atomic)

        let id = DeviceIDStore(url: url).stableDeviceID()
        #expect(isCanonicalUUID(id))
    }

    @Test
    func separateStoresMintDistinctIDs() throws {
        let urlA = try makeTempDeviceIDURL()
        let urlB = try makeTempDeviceIDURL()
        defer {
            try? FileManager.default.removeItem(at: urlA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: urlB.deletingLastPathComponent())
        }

        let idA = DeviceIDStore(url: urlA).stableDeviceID()
        let idB = DeviceIDStore(url: urlB).stableDeviceID()
        #expect(idA != idB)
    }

    @Test
    func mintedFileIsExcludedFromBackup() throws {
        let url = try makeTempDeviceIDURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = DeviceIDStore(url: url).stableDeviceID()

        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test
    func saveCreatesMissingParentDirectory() throws {
        // A nested path whose parent does not exist yet must be created on mint.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-deviceid-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let url = dir.appendingPathComponent("device-id")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let id = DeviceIDStore(url: url).stableDeviceID()
        #expect(isCanonicalUUID(id))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
