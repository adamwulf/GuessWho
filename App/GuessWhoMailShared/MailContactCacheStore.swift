import Foundation

/// Reads and writes the `MailContactSnapshot` file shared by the app (the only
/// writer) and the Mail extension (a reader on every incoming message).
///
/// The file is a binary property list, so thumbnail bytes are stored raw
/// rather than base64-inflated. `read()` keeps the last decoded snapshot and
/// only decodes again when the file on disk changed (inode, size, or
/// modification date), because Mail can deliver hundreds of messages in a
/// burst and each one asks for the same snapshot.
///
/// `@unchecked Sendable`: the only mutable state is `memo`, and every access
/// to it holds `lock`.
final class MailContactCacheStore: @unchecked Sendable {
    let fileURL: URL

    private let lock = NSLock()
    private var memo: (stamp: FileStamp, snapshot: MailContactSnapshot)?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The store at the shared App Group location, or nil when this bundle has
    /// no usable `GuessWhoAppGroup` container.
    static func shared(in bundle: Bundle = .main) -> MailContactCacheStore? {
        MailHandoffContainer.contactCacheURL(in: bundle).map(MailContactCacheStore.init(fileURL:))
    }

    /// The current snapshot, or nil when the app hasn't published one yet.
    /// Throws when the file can't be read or decoded, or was written by a
    /// newer build (`MailHandoffError.unsupportedVersion`).
    func read() throws -> MailContactSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return try MailFileCoordination.read(fileURL) { url in
            guard let stamp = try FileStamp(of: url) else {
                memo = nil
                return nil
            }
            if let memo, memo.stamp == stamp {
                return memo.snapshot
            }
            guard let data = try MailFileCoordination.contentsIfPresent(of: url) else {
                memo = nil
                return nil
            }
            let snapshot = try Self.decode(data)
            memo = (stamp, snapshot)
            return snapshot
        }
    }

    /// Replaces the published snapshot atomically.
    func write(_ snapshot: MailContactSnapshot) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try MailFileCoordination.write(fileURL) { url in
            try data.write(to: url, options: .atomic)
        }
    }

    private static func decode(_ data: Data) throws -> MailContactSnapshot {
        let decoder = PropertyListDecoder()
        let probe = try decoder.decode(VersionProbe.self, from: data)
        guard probe.version <= MailContactSnapshot.currentVersion else {
            throw MailHandoffError.unsupportedVersion(probe.version)
        }
        return try decoder.decode(MailContactSnapshot.self, from: data)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Identifies one on-disk version of the file. An atomic replace always
    /// changes the inode, so a rewrite is caught even when the size and the
    /// (second-granular on some volumes) modification date both match.
    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        /// Nil when no file exists at `url`.
        init?(of url: URL) throws {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date ?? .distantPast
        }
    }
}
