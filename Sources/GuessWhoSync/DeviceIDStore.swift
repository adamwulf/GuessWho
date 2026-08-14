import Foundation

/// Device-local persistence for the stable device identifier — a minted UUID,
/// reused per device, that keys per-device slots in synced records (e.g. the
/// `deviceLocalIDs` map on a group-identity record).
///
/// Same "device-local, safe to lose, regenerate on loss" contract as
/// `ContactSyncCursorStore`: the value NEVER rides iCloud (the file is marked
/// `isExcludedFromBackup`), and a lost file just mints a fresh id on the next
/// read. Unlike `identifierForVendor` this carries no UIKit dependency (the
/// package is UIKit-free) and does not reset when the vendor's apps are all
/// removed — it is our own file, minted once and reused.
///
/// The canonical form is a lowercased UUID string. `stableDeviceID()` returns an
/// existing canonical value, canonicalizes (lowercases and rewrites) a stored
/// value that parses as a UUID but is not yet canonical, or atomically mints and
/// persists a fresh UUID when the file is absent or holds a non-UUID value.
public struct DeviceIDStore: Sendable {
    private let url: URL

    /// Serializes load-or-mint across every store in the process so two
    /// concurrent callers — even over the same path — can never mint and persist
    /// divergent ids. Also guards `cache` below; every read and write of it
    /// happens while this lock is held. Mints are rare (once per device), so a
    /// single process-wide lock is more than cheap enough.
    private static let mintLock = NSLock()

    /// Process-local id cache, keyed by the standardized file path. Populated for
    /// both loaded and freshly minted ids so a caller always sees the SAME id for
    /// a given path within the process — even when persisting failed (a read-only
    /// volume, an uncreatable parent) and the file therefore holds nothing. Only
    /// touched under `mintLock`; `nonisolated(unsafe)` documents that manual
    /// synchronization rather than compiler isolation makes it safe.
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// The cache key for `url` — its standardized filesystem path, so different
    /// spellings of the same file (`.`/`..` segments, trailing slash) share one
    /// entry.
    private static func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// - Parameter url: the device-local file the id is stored at. The caller
    ///   owns the path; the parent directory is created on write if needed.
    public init(url: URL) {
        self.url = url
    }

    /// Returns the stable device id, minting and persisting one if needed.
    ///
    /// Always yields a usable lowercased UUID string, and always the SAME one for
    /// a given path within the process. Persisting is best-effort: if the write
    /// fails (e.g. a read-only volume) the id is held in `cache` so repeat calls
    /// still reuse it — it just won't survive a relaunch, the same "safe to lose"
    /// degradation as the change cursor.
    public func stableDeviceID() -> String {
        Self.mintLock.lock()
        defer { Self.mintLock.unlock() }

        let key = Self.cacheKey(for: url)
        if let cached = Self.cache[key] {
            return cached
        }
        let id: String
        if let canonical = loadCanonical() {
            id = canonical
        } else {
            let fresh = UUID().uuidString.lowercased()
            try? persist(fresh)
            id = fresh
        }
        Self.cache[key] = id
        return id
    }

    /// Reads the persisted id, returning it in canonical lowercase form, or
    /// `nil` when the file is absent, unreadable, or does not parse as a UUID
    /// (which the caller treats as "mint a fresh id").
    ///
    /// A value that parses as a UUID but is not already canonical (e.g. an
    /// uppercase string) is REUSED, not discarded — the device keeps its
    /// identity — and the file is rewritten to the canonical form so it
    /// converges.
    private func loadCanonical() -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        let canonical = uuid.uuidString.lowercased()
        if canonical != trimmed {
            try? persist(canonical)
        }
        return canonical
    }

    /// Atomically writes the id, creating the parent directory if needed, and
    /// marks the file excluded from iCloud backup so it stays device-local.
    private func persist(_ id: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(id.utf8).write(to: url, options: .atomic)
        try setExcludedFromBackup()
    }

    /// Sets `isExcludedFromBackup` on the id file so it never rides iCloud
    /// backup. Mutating resource values requires a `var` URL copy.
    private func setExcludedFromBackup() throws {
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try fileURL.setResourceValues(values)
    }
}
