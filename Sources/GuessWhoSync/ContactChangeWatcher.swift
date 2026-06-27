#if canImport(Contacts)
import Contacts
#endif
import Foundation
import Logging

/// Owns the external-contact-change pipeline that used to live in the app's
/// `ContactsRepository`: the `.CNContactStoreDidChange` observer, the
/// change-history cursor, the run-in-flight coalescing, and the delta read via
/// `ContactStoreProtocol.changes(since:)`. Subscribers become dumb consumers of
/// the `.guessWhoContactsDidChange` notification this watcher posts.
///
/// `@MainActor` for the same reason the old repository code was: it makes the
/// `isApplying` check-and-set atomic (two `.CNContactStoreDidChange`
/// notifications can land back-to-back), and it lets the apply path run with
/// consistent state. The long-lived `GuessWhoSync` instance owns one of these
/// and starts/stops it; it is opt-in (nothing observes until `start()`) so tests
/// and non-UI contexts never auto-register.
///
/// Registration uses the **selector-based** `addObserver(_:selector:name:object:)`
/// API, NOT the block API. Per Apple's docs, an app targeting iOS 9 /
/// macOS 10.11 or later that registers with the selector API does NOT need to
/// unregister — NotificationCenter holds the observer weakly and "cleans up the
/// next time it would have posted to it." This package targets iOS 17 /
/// macOS 14, so there is no `deinit` teardown obligation. (The block API, by
/// contrast, strongly retains its block until you `removeObserver`.) The `@objc`
/// trampoline is `nonisolated` because the selector API delivers on the posting
/// thread; it hops onto the main actor before touching any state.
@MainActor
public final class ContactChangeWatcher: NSObject {
    /// Routes change-pipeline breadcrumbs through swift-log. With the app's
    /// logging backend bootstrapped these land in `<AppGroup>/Logs/app.log`
    /// (and echo to Console); under `swift test` (no bootstrap) they fall back
    /// to swift-log's default stderr handler. Developer-facing — internal
    /// vocabulary is fine in the message body.
    private static let log = Logger(label: "sync.contact-change-watcher")

    private let contacts: ContactStoreProtocol
    private let cursorStore: ContactSyncCursorStore
    private let notificationCenter: NotificationCenter

    /// Whether `start()` has registered the observer. Tracked only so `start()`
    /// is idempotent; teardown is automatic (weak observer) so no token is kept.
    private var isObserving = false

    /// Guards `processChanges()` against overlapping invocations. Two
    /// `.CNContactStoreDidChange` notifications can land back-to-back; without
    /// this, the second could interleave a half-applied delta. `@MainActor`
    /// makes the check-and-set atomic.
    private var isProcessing = false

    /// Set when a notification arrives while a run is already in flight. Without
    /// it, a write that commits AFTER the in-flight run's `changes(since:)` read
    /// but whose notification lands DURING the apply would be stranded until the
    /// next unrelated store change — because the cursor advances past it.
    /// Draining this flag re-runs once more to pick up exactly that window.
    /// Coalesces multiple rejected notifications into a single re-run.
    private var changesPending = false

    /// - Parameters:
    ///   - contacts: the store the delta is read from (`changes(since:)`). The
    ///     same conformer `GuessWhoSync` already drives its other reads through.
    ///   - cursorStore: device-local persistence for the change-history cursor.
    ///   - notificationCenter: injectable so tests can post/observe in isolation;
    ///     defaults to `.default`.
    public init(
        contacts: ContactStoreProtocol,
        cursorStore: ContactSyncCursorStore,
        notificationCenter: NotificationCenter = .default
    ) {
        self.contacts = contacts
        self.cursorStore = cursorStore
        self.notificationCenter = notificationCenter
        super.init()
    }

    /// Begin observing `.CNContactStoreDidChange`. Opt-in — until this is called
    /// nothing is registered, so tests and non-UI contexts stay quiet. Idempotent:
    /// a second call while already observing is a no-op. No teardown is required;
    /// the weak selector-based registration is cleaned up automatically when this
    /// instance is released (see the type docs).
    public func start() {
        #if canImport(Contacts)
        guard !isObserving else { return }
        notificationCenter.addObserver(
            self,
            selector: #selector(contactStoreDidChange(_:)),
            name: .CNContactStoreDidChange,
            object: nil
        )
        isObserving = true
        #endif
    }

    /// `@objc` trampoline for the selector-based registration. `nonisolated`
    /// because the selector API delivers on the posting thread (which for
    /// `.CNContactStoreDidChange` is not guaranteed to be main); it hops onto the
    /// main actor before touching any state. `processChanges()` coalesces
    /// back-to-back notifications, so spawning a fresh Task per notification is
    /// safe.
    @objc
    private nonisolated func contactStoreDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            await self?.processChanges()
        }
    }

    /// Read the external contact-store delta since the persisted cursor and post
    /// `.guessWhoContactsDidChange` describing what changed. Public so tests can
    /// drive it directly (simulating a `.CNContactStoreDidChange` firing) without
    /// posting a real system notification.
    ///
    /// Contract:
    /// - `requiresFullReload` (first run / DropEverything / read failure) → post
    ///   the full-reload payload so the subscriber drops its cache and re-reads.
    /// - A non-empty delta → post the `ContactChangeSet`.
    /// - An EMPTY delta (e.g. our own writes, excluded via `transactionAuthor`)
    ///   → post NOTHING, but still advance the cursor.
    /// - Persist the cursor ONLY after a successful read, so a crash mid-apply
    ///   re-processes rather than skips. A read failure leaves the cursor
    ///   untouched so the next attempt retries from the same point.
    ///
    /// Overlap handling: if a notification arrives mid-run, `changesPending` is
    /// set and drained by a single extra pass after the current one finishes, so
    /// a write whose notification lands during the apply is never stranded.
    public func processChanges() async {
        guard !isProcessing else {
            // A run is in flight. Mark that another pass is needed rather than
            // dropping this notification — the in-flight run advances the cursor,
            // so without a re-run a write that committed after its history read
            // would be stranded until the next unrelated store change.
            changesPending = true
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        // Run at least once; re-run while a notification arrived mid-apply.
        repeat {
            changesPending = false
            await processChangesOnce()
        } while changesPending
    }

    private func processChangesOnce() async {
        let token = cursorStore.load()
        let changeSet: ContactChangeSet
        do {
            changeSet = try await contacts.changes(since: token)
        } catch {
            // Auth / I-O failure reading history → tell the subscriber to do a
            // full reload; leave the cursor untouched so the next attempt
            // retries from the same point. The watcher has no UI-visible error
            // channel (it is not the old @Observable repository), so leave a
            // breadcrumb: without it, a transient "read failed but the recovery
            // reload succeeded" is otherwise invisible. Routes through swift-log
            // so it lands in the log file alongside the rest of the app's logs.
            Self.log.error("contact change read failed", metadata: ["error": .string(String(describing: error))])
            postFullReload()
            return
        }

        if changeSet.requiresFullReload {
            // First run / DropEverything: the partial delta is meaningless. The
            // subscriber rebuilds from a full reload; advance the cursor to the
            // fresh baseline so the next read starts after it.
            postFullReload()
            saveCursor(changeSet.newToken)
            return
        }

        // A non-empty delta is handed to the subscriber to apply IN ORDER.
        // An empty delta posts NOTHING (a self-write still fires
        // `.CNContactStoreDidChange`, but its delta is empty after author
        // exclusion) while still advancing the cursor below.
        if !changeSet.changes.isEmpty {
            postChangeSet(changeSet)
        }
        // Advance the cursor even on an empty delta — the history position moved
        // (e.g. our own excluded writes), so the next read should start after it.
        saveCursor(changeSet.newToken)
    }

    // MARK: - Posting

    private func postChangeSet(_ changeSet: ContactChangeSet) {
        notificationCenter.post(
            name: .guessWhoContactsDidChange,
            object: self,
            userInfo: [GuessWhoContactsDidChangeKey.changeSet: changeSet]
        )
    }

    private func postFullReload() {
        notificationCenter.post(
            name: .guessWhoContactsDidChange,
            object: self,
            userInfo: [GuessWhoContactsDidChangeKey.requiresFullReload: true]
        )
    }

    private func saveCursor(_ token: Data) {
        // A write failure is non-fatal — it just means the next launch re-reads
        // from the older cursor (idempotent re-apply). Swallow it; the cursor is
        // a cache, safe to lose.
        try? cursorStore.save(token)
    }
}
