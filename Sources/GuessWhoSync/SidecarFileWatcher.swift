import Foundation
import Logging

public extension Notification.Name {
    /// Posted by `SidecarFileWatcher` when sidecar files under the iCloud
    /// root change on disk — a remote edit or a `notYetDownloaded` file
    /// arriving from another device, or a same-device write echoing back
    /// through the metadata query (see `SidecarFileWatcher` for why echoes
    /// are accepted rather than filtered). The notification carries a
    /// `SidecarChangeSet` when the metadata delivery names concrete files;
    /// subscribers fall back to their full refresh when it does not.
    ///
    /// This is the missing half of the `SidecarStoreError.notYetDownloaded`
    /// contract: `read()` requests the download and tells the caller to retry
    /// later; this notification is what makes "later" actually happen without
    /// waiting for an unrelated reload trigger.
    ///
    /// The name is developer/internal-facing; the `guessWho` vocabulary is
    /// intentional and never surfaces in any user-facing string.
    static let guessWhoSidecarsDidChange = Notification.Name("GuessWhoSidecarsDidChange")
}

/// `userInfo` keys for `.guessWhoSidecarsDidChange`.
public enum GuessWhoSidecarsDidChangeKey {
    /// Value: a `SidecarChangeSet`. Its `changedKeys` is nil when the watcher
    /// cannot safely identify every changed file, including initial gather.
    public static let changeSet = "changeSet"
}

/// The sidecar keys named by one coalesced metadata-query burst. A nil key set
/// is an explicit full-refresh signal. Empty sets are normalized to nil so an
/// incomplete or synthetic metadata delivery can never suppress a refresh.
public struct SidecarChangeSet: Sendable, Equatable {
    public let changedKeys: Set<SidecarKey>?

    public init(changedKeys: Set<SidecarKey>?) {
        if let changedKeys, !changedKeys.isEmpty {
            self.changedKeys = changedKeys
        } else {
            self.changedKeys = nil
        }
    }

    public static let fullRefresh = SidecarChangeSet(changedKeys: nil)

    public var requiresFullRefresh: Bool { changedKeys == nil }

    /// Unknown scope is contagious: if either delivery cannot name every key,
    /// the combined burst must retain the full-refresh fallback.
    public func merging(_ other: SidecarChangeSet) -> SidecarChangeSet {
        guard let changedKeys, let otherKeys = other.changedKeys else {
            return .fullRefresh
        }
        return SidecarChangeSet(changedKeys: changedKeys.union(otherKeys))
    }
}

public extension Notification {
    /// Typed payload for `.guessWhoSidecarsDidChange`. A missing or malformed
    /// payload preserves compatibility with coarse legacy/test posts by
    /// returning the guaranteed full-refresh fallback.
    var guessWhoSidecarChangeSet: SidecarChangeSet {
        userInfo?[GuessWhoSidecarsDidChangeKey.changeSet] as? SidecarChangeSet
            ?? .fullRefresh
    }
}

/// Watches the sidecar root in the iCloud ubiquity container with an
/// `NSMetadataQuery`. On initial gather and whenever files under it change, it
/// first reconciles unresolved iCloud file versions and then posts
/// `.guessWhoSidecarsDidChange`: repositories never refresh from a known
/// conflicted snapshot.
///
/// Mirrors `ContactChangeWatcher`'s shape: `@MainActor`, opt-in `start()`
/// (nothing observes until then, so tests and non-UI contexts stay quiet),
/// idempotent, selector-based observation with no teardown obligation, an
/// injectable `NotificationCenter` so tests post/observe in isolation, and
/// `nonisolated` `@objc` trampolines that hop onto the main actor before
/// touching state.
///
/// SELF-ECHO (accepted, by design): this device's own sidecar writes also
/// fire metadata updates (upload-state transitions), and NSMetadataQuery
/// offers no reliable "was this change remote?" discriminator — a
/// download-completed item and an upload-completed item both settle to the
/// same "current" status. So the watcher posts for both, and safety comes
/// from the subscriber side: every subscriber refresh path is READ-ONLY over
/// sidecars (no write-back, so no loop) and debounced (so a burst costs one
/// refresh). If echo refreshes ever prove noisy in practice, the escape
/// hatch is store-side write journaling (compare changed paths against
/// recent local writes), not query-side filtering.
///
/// The query itself batches notifications, and the watcher adds a trailing
/// quiet period before reconciliation. A burst therefore reaches subscribers
/// as one reconcile-and-post pass (which they debounce again).
@MainActor
public final class SidecarFileWatcher: NSObject {
    /// Breadcrumbs for the arrival pipeline, alongside the rest of the app's
    /// logs. Developer-facing — internal vocabulary is fine in the body.
    private static let log = Logger(label: "sync.sidecar-file-watcher")

    private let root: URL
    private let sync: GuessWhoSync
    private let notificationCenter: NotificationCenter
    private let query = NSMetadataQuery()

    /// Whether `start()` has configured and started the query. Tracked only so
    /// `start()` is idempotent.
    private var isObserving = false

    /// Metadata notifications first collect here until the trailing quiet
    /// period expires. A separate ready batch is necessary because a new
    /// delivery can restart the quiet period while an older ready batch is
    /// waiting for the current reconciliation pass to finish.
    private struct ChangeBatch {
        var added: Int
        var changed: Int
        var removed: Int
        var changeSet: SidecarChangeSet

        mutating func merge(
            added: Int,
            changed: Int,
            removed: Int,
            changeSet: SidecarChangeSet
        ) {
            self.added += added
            self.changed += changed
            self.removed += removed
            self.changeSet = self.changeSet.merging(changeSet)
        }

        mutating func merge(_ other: ChangeBatch) {
            merge(
                added: other.added,
                changed: other.changed,
                removed: other.removed,
                changeSet: other.changeSet
            )
        }
    }

    /// Named independently from `notificationBatchingInterval`: batching is
    /// upstream delivery policy, while this is the trailing-edge quiet period
    /// that coalesces deliveries before expensive work starts.
    private static let changeProcessingQuietPeriod: Duration = .milliseconds(500)
    private var pendingQuietPeriod: Task<Void, Never>?
    private var pendingBatch: ChangeBatch?
    private var readyBatch: ChangeBatch?

    /// Metadata notifications can arrive while a reconciliation pass is still
    /// waiting on cloudd. Coalesce quieted batches into at most one follow-up
    /// pass rather than running overlapping whole-tree scans.
    private var isProcessingChanges = false
    private var needsAnotherPass = false

    /// - Parameters:
    ///   - root: the sidecar root INSIDE the ubiquity container (the
    ///     `Documents/` directory `SyncService` resolves). The query scopes to
    ///     ubiquitous Documents and predicates on this path prefix, so only
    ///     sidecar-tree items (envelopes, blobs, `Favorites.json`, and their
    ///     `.icloud` placeholders) match.
    ///   - sync: the same engine production repositories use for sidecar reads
    ///     and writes. Its async reconciler hops coordinated disk work off the
    ///     main actor.
    ///   - notificationCenter: where `.guessWhoSidecarsDidChange` is posted.
    ///     Injectable so tests can observe in isolation; defaults to `.default`.
    public init(
        root: URL,
        sync: GuessWhoSync,
        notificationCenter: NotificationCenter = .default
    ) {
        self.root = root
        self.sync = sync
        self.notificationCenter = notificationCenter
        super.init()
    }

    /// Configure and start the metadata query. Opt-in and idempotent — a
    /// second call is a no-op. Call from the main actor after launch wiring
    /// (`GuessWhoAppDelegate` does, next to `startContactChangeWatcher()`).
    ///
    /// Only meaningful when the sidecar root lives in the ubiquity container:
    /// the ubiquitous-Documents scope matches nothing for a local-fallback
    /// root, so a mis-wired watcher degrades to silence, never wrong posts.
    public func start() {
        guard !isObserving else { return }
        isObserving = true

        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Prefix match on the resolved root path (trailing slash so a sibling
        // directory sharing the prefix can't match). NSMetadataItemPathKey is
        // the item's resolved filesystem path in the same namespace
        // `url(forUbiquityContainerIdentifier:)` vends, so the two agree.
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            root.standardizedFileURL.path + "/"
        )
        // Collapse rapid-fire file events (a multi-file sync burst) into at
        // most one didUpdate per second; subscribers debounce on top of this.
        query.notificationBatchingInterval = 1.0
        // Deliver query notifications on the main queue so delivery order and
        // isolation are predictable; the trampolines still hop via Task per
        // the watcher convention (selector delivery is thread-of-poster).
        query.operationQueue = .main

        // The query's OWN notifications always post on `.default` (that is
        // NSMetadataQuery's behavior, not ours), so observe them there — the
        // injected `notificationCenter` isolates only the OUTBOUND
        // `.guessWhoSidecarsDidChange` post. `object: query` scopes delivery
        // to this watcher's query instance.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )

        query.start()
    }

    /// Initial gather completed. This is the launch-time conflict-recovery
    /// trigger: unresolved versions may predate this process and therefore
    /// produce no live update notification after the watcher starts.
    @objc
    private nonisolated func queryDidFinishGathering(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.log.info(
                "sidecar metadata query gathered",
                metadata: ["results": .stringConvertible(self.query.resultCount)]
            )
            self.scheduleChangeProcessing(
                added: self.query.resultCount,
                changed: 0,
                removed: 0,
                changedKeys: nil
            )
        }
    }

    /// Live update from the query: something under the root changed. Counts
    /// are read from userInfo HERE (delivery-side) because the arrays are
    /// only guaranteed coherent with this notification, then the post happens
    /// on the main actor.
    @objc
    private nonisolated func queryDidUpdate(_ note: Notification) {
        let addedItems = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [Any] ?? []
        let changedItems = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any] ?? []
        let removedItems = note.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [Any] ?? []
        let paths = (addedItems + changedItems + removedItems).compactMap(Self.metadataPath)
        let itemCount = addedItems.count + changedItems.count + removedItems.count
        Task { @MainActor [weak self] in
            guard let self else { return }
            let changedKeys: Set<SidecarKey>?
            if paths.count == itemCount {
                let mappedKeys = paths.compactMap(self.sidecarKey(forMetadataPath:))
                changedKeys = mappedKeys.count == paths.count ? Set(mappedKeys) : nil
            } else {
                changedKeys = nil
            }
            // A path that cannot be mapped to a SidecarKey (for example a
            // directory or root-level support file) makes scope unknown.
            self.scheduleChangeProcessing(
                added: addedItems.count,
                changed: changedItems.count,
                removed: removedItems.count,
                changedKeys: changedKeys
            )
        }
    }

    private nonisolated static func metadataPath(from item: Any) -> String? {
        if let metadataItem = item as? NSMetadataItem {
            return metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String
        }
        if let url = item as? URL { return url.path }
        return item as? String
    }

    /// Internal so the external-input parser can be covered without requiring
    /// a live metadata query.
    func sidecarKey(forMetadataPath path: String) -> SidecarKey? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let itemComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard itemComponents.count == rootComponents.count + 2,
              Array(itemComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }

        let kind: SidecarKind
        switch itemComponents[rootComponents.count] {
        case "contacts": kind = .contact
        case "events": kind = .event
        case "links": kind = .link
        case "guides": kind = .guide
        case "places": kind = .place
        case "groups": kind = .group
        default: return nil
        }

        var filename = itemComponents.last ?? ""
        if filename.hasPrefix("."),
           filename.hasSuffix(".icloud"),
           filename.count > ".icloud".count
        {
            filename.removeFirst()
            filename.removeLast(".icloud".count)
        }

        let id: String
        if filename.hasSuffix(".json") {
            id = String(filename.dropLast(".json".count))
        } else if filename.hasSuffix(".dat"), let separator = filename.firstIndex(of: ".") {
            id = String(filename[..<separator])
        } else {
            return nil
        }
        guard !id.isEmpty else { return nil }
        let decodedID = kind == .event ? (id.removingPercentEncoding ?? id) : id
        return SidecarKey(kind: kind, id: decodedID)
    }

    /// Internal so tests can drive the production debounce without requiring
    /// a live ubiquity container.
    func scheduleChangeProcessing(
        added: Int,
        changed: Int,
        removed: Int,
        changedKeys: Set<SidecarKey>?
    ) {
        let changeSet = SidecarChangeSet(changedKeys: changedKeys)
        if pendingBatch == nil {
            pendingBatch = ChangeBatch(
                added: added,
                changed: changed,
                removed: removed,
                changeSet: changeSet
            )
        } else {
            pendingBatch?.merge(
                added: added,
                changed: changed,
                removed: removed,
                changeSet: changeSet
            )
        }

        pendingQuietPeriod?.cancel()
        pendingQuietPeriod = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.changeProcessingQuietPeriod)
            } catch {
                return
            }
            self?.quietPeriodElapsed()
        }
    }

    private func quietPeriodElapsed() {
        pendingQuietPeriod = nil
        guard let batch = pendingBatch else { return }
        pendingBatch = nil
        if readyBatch == nil {
            readyBatch = batch
        } else {
            readyBatch?.merge(batch)
        }

        if isProcessingChanges {
            needsAnotherPass = true
            return
        }
        startProcessingReadyBatches()
    }

    private func startProcessingReadyBatches() {
        guard !isProcessingChanges, readyBatch != nil else { return }
        isProcessingChanges = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherPass = false
                guard let batch = self.readyBatch else { break }
                self.readyBatch = nil
                await self.processSidecarChanges(
                    added: batch.added,
                    changed: batch.changed,
                    removed: batch.removed,
                    changedKeys: batch.changeSet.changedKeys
                )
            } while self.needsAnotherPass && self.readyBatch != nil
            self.isProcessingChanges = false
        }
    }

    /// The single production change-processing path. Internal so @testable
    /// tests can drive the exact method used by `NSMetadataQuery`, with a real
    /// `GuessWhoSync` over a scripted conflict store. Reconciliation completes
    /// before notification delivery, guaranteeing subscribers read the merged
    /// envelope. A failed pass is logged but still posts: the current version
    /// remains readable, and a later metadata update can retry the conflict.
    func processSidecarChanges(
        added: Int,
        changed: Int,
        removed: Int,
        changedKeys: Set<SidecarKey>? = nil
    ) async {
        Self.log.info(
            "sidecar files changed",
            metadata: [
                "added": .stringConvertible(added),
                "changed": .stringConvertible(changed),
                "removed": .stringConvertible(removed)
            ]
        )

        do {
            // Opportunity #4 owns making this corpus-wide conflict scan incremental.
            let report = try await sync.reconcileSidecars()
            if !report.fileOutcomes.isEmpty {
                let skipped = report.fileOutcomes.reduce(0) { $0 + $1.skippedReasons.count }
                Self.log.notice(
                    "sidecar conflicts reconciled",
                    metadata: [
                        "files": .stringConvertible(report.fileOutcomes.count),
                        "skippedReasons": .stringConvertible(skipped)
                    ]
                )
            }
        } catch {
            Self.log.error(
                "sidecar conflict reconciliation failed",
                metadata: ["error": .string(String(describing: error))]
            )
        }

        notificationCenter.post(
            name: .guessWhoSidecarsDidChange,
            object: self,
            userInfo: [
                GuessWhoSidecarsDidChangeKey.changeSet:
                    SidecarChangeSet(changedKeys: changedKeys)
            ]
        )
    }
}
