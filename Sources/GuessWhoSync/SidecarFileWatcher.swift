import Foundation
import Logging

public extension Notification.Name {
    /// Posted by `SidecarFileWatcher` when sidecar files under the iCloud
    /// root change on disk — a remote edit or a `notYetDownloaded` file
    /// arriving from another device, or a same-device write echoing back
    /// through the metadata query (see `SidecarFileWatcher` for why echoes
    /// are accepted rather than filtered). No payload: subscribers treat it
    /// as a coarse "sidecar-derived state may be stale" signal and run their
    /// (debounced, read-only) refresh paths.
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
/// The query itself batches: `notificationBatchingInterval` collapses rapid
/// file events into one `didUpdate` per interval, so a multi-file sync
/// burst reaches subscribers as a single post (which they debounce again).
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

    /// Metadata notifications can arrive while a reconciliation pass is still
    /// waiting on cloudd. Coalesce them into at most one follow-up pass rather
    /// than running overlapping whole-tree scans. The reconciler's own writes
    /// echo through the metadata query; that echo produces one cheap no-conflict
    /// follow-up and then settles.
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
            self.scheduleChangeProcessing(added: self.query.resultCount, changed: 0, removed: 0)
        }
    }

    /// Live update from the query: something under the root changed. Counts
    /// are read from userInfo HERE (delivery-side) because the arrays are
    /// only guaranteed coherent with this notification, then the post happens
    /// on the main actor.
    @objc
    private nonisolated func queryDidUpdate(_ note: Notification) {
        let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [Any])?.count ?? 0
        let changed = (note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [Any])?.count ?? 0
        let removed = (note.userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [Any])?.count ?? 0
        Task { @MainActor [weak self] in
            self?.scheduleChangeProcessing(added: added, changed: changed, removed: removed)
        }
    }

    private func scheduleChangeProcessing(added: Int, changed: Int, removed: Int) {
        if isProcessingChanges {
            needsAnotherPass = true
            return
        }

        isProcessingChanges = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var counts = (added: added, changed: changed, removed: removed)
            repeat {
                self.needsAnotherPass = false
                await self.processSidecarChanges(
                    added: counts.added,
                    changed: counts.changed,
                    removed: counts.removed
                )
                // A coalesced pass represents an unspecified metadata burst;
                // counts are diagnostics only, so don't repeat stale values.
                counts = (0, 0, 0)
            } while self.needsAnotherPass
            self.isProcessingChanges = false
        }
    }

    /// The single production change-processing path. Internal so @testable
    /// tests can drive the exact method used by `NSMetadataQuery`, with a real
    /// `GuessWhoSync` over a scripted conflict store. Reconciliation completes
    /// before notification delivery, guaranteeing subscribers read the merged
    /// envelope. A failed pass is logged but still posts: the current version
    /// remains readable, and a later metadata update can retry the conflict.
    func processSidecarChanges(added: Int, changed: Int, removed: Int) async {
        Self.log.info(
            "sidecar files changed",
            metadata: [
                "added": .stringConvertible(added),
                "changed": .stringConvertible(changed),
                "removed": .stringConvertible(removed)
            ]
        )

        do {
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

        notificationCenter.post(name: .guessWhoSidecarsDidChange, object: self)
    }
}
