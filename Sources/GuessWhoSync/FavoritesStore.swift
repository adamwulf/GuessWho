import Foundation

/// Single-file store for the user's ordered favorites list. Sits as a
/// sibling of the sidecar `contacts/`/`events/`/`links/` directories under
/// the same Documents root. Hand-rolls its own `NSFileCoordinator` since
/// the sidecar store's coordinator wrappers are private.
///
/// Conflict handling: `Favorites.json` is NOT covered by
/// `FileSystemSidecarStore.reconcileSidecars()`. On read, if iCloud
/// produced unresolved `NSFileVersion` conflicts, `loadAll()` picks the
/// current version as authoritative and best-effort-clears the others so
/// they don't accumulate on disk. Cross-device near-simultaneous reorders
/// are last-writer-wins.
public final class FavoritesStore {
    private let root: URL
    private let queue = DispatchQueue(label: "GuessWhoSync.FavoritesStore.coordinator")

    public init(root: URL) {
        self.root = root
    }

    /// Absolute file path: `<root>/Favorites.json`.
    public var fileURL: URL {
        root.appendingPathComponent("Favorites.json", isDirectory: false)
    }

    public func loadAll() throws -> [Favorite] {
        let url = fileURL
        var loaded: [Favorite] = []
        var readError: Error?
        try coordinatedRead(at: url) { safeURL in
            let fm = FileManager.default
            guard fm.fileExists(atPath: safeURL.path) else {
                loaded = []
                return
            }
            do {
                let data = try Data(contentsOf: safeURL)
                if data.isEmpty {
                    loaded = []
                    return
                }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                loaded = envelope.items
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        // Best-effort conflict cleanup. iCloud may have left unresolved
        // NSFileVersion siblings after a cross-device race; we picked the
        // current version above as authoritative — clear the rest so they
        // don't pile up. Never throws.
        clearUnresolvedConflicts(at: url)
        return loaded
    }

    public func setAll(_ items: [Favorite]) throws {
        let url = fileURL
        let envelope = Envelope(version: 1, items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        var writeError: Error?
        try coordinatedWrite(at: url) { safeURL in
            do {
                try data.write(to: safeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
    }

    /// Returns the new favorite state: `true` if the entity is now favorited
    /// (was added), `false` if it was un-favorited (removed).
    @discardableResult
    public func toggle(kind: FavoriteKind, id: String, now: Date) throws -> Bool {
        let canonical = id.lowercased()
        var items = try loadAll()
        if let index = items.firstIndex(where: { $0.kind == kind && $0.id == canonical }) {
            items.remove(at: index)
            try setAll(items)
            return false
        } else {
            items.append(Favorite(kind: kind, id: canonical, addedAt: now))
            try setAll(items)
            return true
        }
    }

    public func isFavorite(kind: FavoriteKind, id: String) throws -> Bool {
        let canonical = id.lowercased()
        return try loadAll().contains { $0.kind == kind && $0.id == canonical }
    }

    // MARK: - Coordinator wrappers (hand-rolled; sidecar store's are private)

    private func coordinatedRead(at url: URL, _ body: @escaping (URL) -> Void) throws {
        var thrown: Error?
        queue.sync {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { safeURL in
                body(safeURL)
            }
            if let coordError { thrown = coordError }
        }
        if let thrown { throw thrown }
    }

    private func coordinatedWrite(at url: URL, _ body: @escaping (URL) -> Void) throws {
        var thrown: Error?
        queue.sync {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { safeURL in
                body(safeURL)
            }
            if let coordError { thrown = coordError }
        }
        if let thrown { throw thrown }
    }

    /// iCloud surfaces near-simultaneous edits as `NSFileVersion` siblings
    /// that the reconcile path normally clears. `Favorites.json` is outside
    /// that path, so we clear them ourselves on read. Failures are silently
    /// ignored — leaving a conflict version on disk is worse than throwing,
    /// but throwing makes the user-facing read fail too.
    private func clearUnresolvedConflicts(at url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty else { return }
        for version in conflicts {
            version.isResolved = true
            try? version.remove()
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let items: [Favorite]
    }
}
