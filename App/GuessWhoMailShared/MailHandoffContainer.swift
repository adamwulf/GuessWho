import Foundation

/// Where the app and the Mail extension exchange files: a `Mail` directory in
/// the shared App Group container.
///
/// The group id comes ONLY from the running bundle's `GuessWhoAppGroup`
/// Info.plist key (fed by `GUESSWHO_APP_GROUP` in each target's xcconfig), so
/// it always matches that process's signed entitlement. There is no literal
/// fallback: a missing or empty key means "no shared storage", and callers
/// fail open.
enum MailHandoffContainer {
    static let appGroupInfoPlistKey = "GuessWhoAppGroup"
    static let directoryName = "Mail"
    static let contactCacheFileName = "contact-cache.plist"
    static let incomingJournalFileName = "incoming-messages.jsonl"

    static func appGroupIdentifier(in bundle: Bundle = .main) -> String? {
        (bundle.object(forInfoDictionaryKey: appGroupInfoPlistKey) as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The shared `Mail` directory, or nil when the group id is missing or
    /// the process isn't entitled to that container. Not created here —
    /// writers create it on demand.
    static func directoryURL(in bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard let groupID = appGroupIdentifier(in: bundle),
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func contactCacheURL(in bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        directoryURL(in: bundle, fileManager: fileManager)?
            .appendingPathComponent(contactCacheFileName, isDirectory: false)
    }

    static func incomingJournalURL(in bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        directoryURL(in: bundle, fileManager: fileManager)?
            .appendingPathComponent(incomingJournalFileName, isDirectory: false)
    }
}

/// Failures from the shared Mail files. Never shown to the user; the
/// extension logs them and leaves the message alone.
enum MailHandoffError: Error, Equatable {
    /// The file was written by a newer build in a format this one can't read.
    case unsupportedVersion(Int)
}

/// Cross-process file access for the Mail handoff files.
///
/// Every read and write goes through `NSFileCoordinator`, and writes replace
/// the file atomically, so the app and the extension never see a torn file
/// and a read-modify-write is never interleaved with another process's.
enum MailFileCoordination {

    /// Runs `body` under a coordinated read of `url`.
    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        return try unwrap(result, coordinationError)
    }

    /// Runs `body` under a coordinated write of `url`, creating the parent
    /// directory first. `.forMerging` because every writer here reads the
    /// current contents (or replaces them wholesale) inside the same claim.
    static func write<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forMerging, error: &coordinationError
        ) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        return try unwrap(result, coordinationError)
    }

    /// The contents of `url`, or nil when no file exists there yet.
    static func contentsIfPresent(of url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func unwrap<T>(_ result: Result<T, Error>?, _ coordinationError: NSError?) throws -> T {
        if let coordinationError { throw coordinationError }
        guard let result else {
            // The coordinator neither ran the accessor nor reported why.
            throw CocoaError(.fileReadUnknown)
        }
        return try result.get()
    }
}
