import Foundation

// Seam between FileSystemSidecarStore and the iCloud-facing OS APIs
// (NSFileVersion + URLUbiquitousItemDownloadingStatus + ubiquity-download
// kickoff). Production wraps the real APIs 1:1; tests pass an in-memory
// fake so logic that depends on iCloud state can be exercised without a
// real iCloud Drive container.
//
// Scope notes:
//  - NSFileCoordinator is NOT abstracted here. It serializes against
//    cloudd, but the logic we care about (envelope parse, mark resolved,
//    folding the resolver decision) sits ABOVE the coordinator.
//  - The handle returns its bytes via `bytes() throws -> Data` rather
//    than exposing a URL so fakes can stay pure-in-memory. The production
//    adapter reads via `Data(contentsOf: nsVersion.url)` once.
@_spi(ConflictReconcile)
public protocol SidecarUbiquityProvider {
    func unresolvedConflictVersions(at url: URL) -> [SidecarVersionHandle]?

    // Returns nil when there is no current version on disk for this URL
    // (e.g. file truly missing). Throws on read failure — the caller
    // surfaces that as "abort the pass" per PLAN §11 step 11.
    func currentVersionBytes(at url: URL) throws -> Data?

    func downloadingStatus(for url: URL) -> URLUbiquitousItemDownloadingStatus?

    func startDownloading(at url: URL) throws
}

@_spi(ConflictReconcile)
public protocol SidecarVersionHandle: AnyObject {
    func bytes() throws -> Data
    var isResolved: Bool { get set }
    func remove() throws
}

// Production adapter — wraps NSFileVersion + FileManager + URLResourceValues.
// No logic of its own beyond the OS-API delegation.
@_spi(ConflictReconcile)
public struct ProductionUbiquityProvider: SidecarUbiquityProvider {
    public init() {}

    public func unresolvedConflictVersions(at url: URL) -> [SidecarVersionHandle]? {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) else {
            return nil
        }
        return versions.map(NSFileVersionHandle.init)
    }

    public func currentVersionBytes(at url: URL) throws -> Data? {
        guard let current = NSFileVersion.currentVersionOfItem(at: url) else {
            return nil
        }
        return try Data(contentsOf: current.url)
    }

    public func downloadingStatus(for url: URL) -> URLUbiquitousItemDownloadingStatus? {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
        guard let raw = try? url.resourceValues(forKeys: keys).allValues else {
            return nil
        }
        guard let rawStatus = raw[.ubiquitousItemDownloadingStatusKey] as? String else {
            return nil
        }
        return URLUbiquitousItemDownloadingStatus(rawValue: rawStatus)
    }

    public func startDownloading(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

@_spi(ConflictReconcile)
public final class NSFileVersionHandle: SidecarVersionHandle {
    private let version: NSFileVersion

    public init(_ version: NSFileVersion) {
        self.version = version
    }

    public func bytes() throws -> Data {
        try Data(contentsOf: version.url)
    }

    public var isResolved: Bool {
        get { version.isResolved }
        set { version.isResolved = newValue }
    }

    public func remove() throws {
        try version.remove()
    }
}
