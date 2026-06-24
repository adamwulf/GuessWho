import Foundation

/// Device-local persistence for the contact change-history cursor (the opaque
/// `Data` token returned in `ContactChangeSet.newToken`).
///
/// The token is per-device contact-store state: a token from device A is
/// meaningless on device B, so it must NOT ride iCloud. This store writes to a
/// caller-provided URL (the app passes a device-local Application Support path;
/// tests pass a temp dir) and marks the file `isExcludedFromBackup` so it never
/// syncs or backs up. The cursor is a cache, safe to lose — a missing file
/// reads back as `nil`, which the caller treats as a first run (one full reload
/// re-baselines it).
public struct ContactSyncCursorStore: Sendable {
    private let url: URL

    /// - Parameter url: the device-local file the cursor is stored at. The
    ///   caller owns the path; the parent directory is created on write if
    ///   needed.
    public init(url: URL) {
        self.url = url
    }

    /// Returns the persisted cursor, or `nil` if no cursor has been written yet
    /// (or the file is missing). A `nil` result means "first run".
    public func load() -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Persists the cursor, replacing any prior value, and marks the file as
    /// excluded from iCloud backup so it stays device-local. Callers should only
    /// save AFTER a successful delta apply, so a crash mid-apply re-processes
    /// rather than skips.
    public func save(_ token: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try token.write(to: url, options: .atomic)
        try setExcludedFromBackup()
    }

    /// Sets `isExcludedFromBackup` on the cursor file so it never rides iCloud
    /// backup. Mutating resource values requires a `var` URL copy.
    private func setExcludedFromBackup() throws {
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try fileURL.setResourceValues(values)
    }
}
