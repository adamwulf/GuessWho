import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Covers the package-owned `ContactChangeWatcher`: the watcher reads the
/// external delta, advances the cursor, and posts `.guessWhoContactsDidChange`
/// — but ONLY when there is real work. An empty self-write delta advances the
/// cursor silently; a first run / DropEverything posts the full-reload payload.
///
/// `@MainActor` because the watcher is main-actor isolated (its coalescing
/// check-and-set relies on that atomicity, mirroring the old repository code).
/// Each test uses its own `NotificationCenter` so posts never cross between
/// tests, and drives `processChanges()` directly instead of firing a real
/// `.CNContactStoreDidChange` system notification.
@MainActor
@Suite("ContactChangeWatcher")
struct ContactChangeWatcherTests {
    /// Collects `.guessWhoContactsDidChange` posts on an isolated center,
    /// extracting the Sendable payload synchronously inside the observer block.
    private final class Recorder {
        struct Post {
            let changeSet: ContactChangeSet?
            let requiresFullReload: Bool
        }
        private(set) var posts: [Post] = []
        private var token: NSObjectProtocol?

        init(center: NotificationCenter) {
            token = center.addObserver(
                forName: .guessWhoContactsDidChange,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let changeSet = note.userInfo?[GuessWhoContactsDidChangeKey.changeSet] as? ContactChangeSet
                let full = note.userInfo?[GuessWhoContactsDidChangeKey.requiresFullReload] as? Bool ?? false
                self?.posts.append(Post(changeSet: changeSet, requiresFullReload: full))
            }
        }

        func stop(center: NotificationCenter) {
            if let token { center.removeObserver(token) }
            token = nil
        }
    }

    private func makeTempCursorURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-watcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contacts-change-cursor")
    }

    private func sampleContact(localID: String) -> Contact {
        Contact(localID: localID, givenName: "Ada", familyName: "Lovelace")
    }

    // MARK: - (a) non-empty external delta posts the change set

    @Test
    func nonEmptyExternalDeltaPostsChangeSet() async throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cursorStore = ContactSyncCursorStore(url: url)
        let store = InMemoryContactStore()
        let center = NotificationCenter()
        let recorder = Recorder(center: center)
        defer { recorder.stop(center: center) }

        // Baseline the cursor so the watcher is "caught up" — this isolates the
        // delta path from the first-run full-reload path.
        let baseline = try await store.changes(since: nil)
        try cursorStore.save(baseline.newToken)

        // An EXTERNAL edit lands (a different transaction author than ours).
        try await store.save(sampleContact(localID: "ext"), author: "external")

        let watcher = ContactChangeWatcher(
            contacts: store,
            cursorStore: cursorStore,
            notificationCenter: center
        )
        await watcher.processChanges()

        // Exactly one post, carrying the delta, not a full-reload flag.
        #expect(recorder.posts.count == 1)
        let post = try #require(recorder.posts.first)
        #expect(post.requiresFullReload == false)
        #expect(post.changeSet?.changes == [.updated(localID: "ext")])

        // Cursor advanced: a second pass with no new edits posts nothing more.
        await watcher.processChanges()
        #expect(recorder.posts.count == 1)
    }

    // MARK: - (b) empty self-write delta posts nothing but advances the cursor

    @Test
    func emptySelfWriteDeltaPostsNothingButAdvancesCursor() async throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cursorStore = ContactSyncCursorStore(url: url)
        let store = InMemoryContactStore()
        let center = NotificationCenter()
        let recorder = Recorder(center: center)
        defer { recorder.stop(center: center) }

        // Baseline, then make ONLY a self-authored write — excluded from the
        // delta exactly as our own writes are in production.
        let baseline = try await store.changes(since: nil)
        try cursorStore.save(baseline.newToken)
        try await store.save(
            sampleContact(localID: "self"),
            author: InMemoryContactStore.selfTransactionAuthor
        )

        let watcher = ContactChangeWatcher(
            contacts: store,
            cursorStore: cursorStore,
            notificationCenter: center
        )
        await watcher.processChanges()

        // Posts NOTHING — the delta was empty after author exclusion.
        #expect(recorder.posts.isEmpty)

        // But the cursor ADVANCED past the self-write: the persisted token now
        // equals the store head, so a subsequent EXTERNAL edit surfaces alone
        // (the self-write is never replayed).
        #expect(cursorStore.load() != baseline.newToken)
        try await store.save(sampleContact(localID: "ext"), author: "external")
        await watcher.processChanges()
        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.changeSet?.changes == [.updated(localID: "ext")])
    }

    // MARK: - (c) first run posts the full-reload payload

    @Test
    func firstRunPostsFullReloadPayload() async throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Fresh cursor store (no file) ⇒ nil token ⇒ first run.
        let cursorStore = ContactSyncCursorStore(url: url)
        #expect(cursorStore.load() == nil)

        let store = InMemoryContactStore()
        try await store.save(sampleContact(localID: "a"), author: "external")
        let center = NotificationCenter()
        let recorder = Recorder(center: center)
        defer { recorder.stop(center: center) }

        let watcher = ContactChangeWatcher(
            contacts: store,
            cursorStore: cursorStore,
            notificationCenter: center
        )
        await watcher.processChanges()

        // Exactly one post, the full-reload signal, with NO change set attached.
        #expect(recorder.posts.count == 1)
        let post = try #require(recorder.posts.first)
        #expect(post.requiresFullReload == true)
        #expect(post.changeSet == nil)

        // Cursor was baselined, so a follow-up with no new edits posts nothing.
        #expect(cursorStore.load() != nil)
        await watcher.processChanges()
        #expect(recorder.posts.count == 1)
    }

    // MARK: - (d) in-order delete-then-readd is posted in history order

    @Test
    func deleteThenReaddIsPostedInHistoryOrder() async throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cursorStore = ContactSyncCursorStore(url: url)
        let store = InMemoryContactStore()
        let center = NotificationCenter()
        let recorder = Recorder(center: center)
        defer { recorder.stop(center: center) }

        // Baseline, then an EXTERNAL delete followed by an EXTERNAL re-add of the
        // SAME localID — the unify/unlink case. The history MUST stay
        // [delete, update] (not bucketed) so a subscriber applying it in order
        // ends with the contact present.
        try await store.save(sampleContact(localID: "x"), author: "external")
        let baseline = try await store.changes(since: nil)
        try cursorStore.save(baseline.newToken)
        try await store.delete(localID: "x", author: "external")
        try await store.save(sampleContact(localID: "x"), author: "external")

        let watcher = ContactChangeWatcher(
            contacts: store,
            cursorStore: cursorStore,
            notificationCenter: center
        )
        await watcher.processChanges()

        // One post, carrying the delta IN ORDER: delete THEN update.
        #expect(recorder.posts.count == 1)
        let post = try #require(recorder.posts.first)
        #expect(post.requiresFullReload == false)
        #expect(post.changeSet?.changes == [
            .deleted(localID: "x"),
            .updated(localID: "x"),
        ])
    }

    // MARK: - (e) a read failure posts full-reload and leaves the cursor untouched

    @Test
    func readThrowPostsFullReloadAndLeavesCursorUntouched() async throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cursorStore = ContactSyncCursorStore(url: url)

        // Seed a known cursor so we can prove it is NOT advanced by the throw.
        let priorToken = Data([0x11, 0x22, 0x33])
        try cursorStore.save(priorToken)

        // Store whose changes(since:) throws once.
        let store = ScriptableContactStore(outcomes: [.throwError])
        let center = NotificationCenter()
        let recorder = Recorder(center: center)
        defer { recorder.stop(center: center) }

        let watcher = ContactChangeWatcher(
            contacts: store,
            cursorStore: cursorStore,
            notificationCenter: center
        )
        await watcher.processChanges()

        // A read failure → tell the subscriber to full-reload …
        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.requiresFullReload == true)
        // … and leave the cursor untouched so the next attempt retries from the
        // same point (no save on the throw branch).
        #expect(cursorStore.load() == priorToken)
    }

    // MARK: - (f) a notification arriving mid-apply drains exactly one extra pass

    @Test
    func notificationArrivingMidApplyDrainsExactlyOnce() async throws {
        let url = try makeTempCursorURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cursorStore = ContactSyncCursorStore(url: url)

        // Two scripted reads. The FIRST parks on a gate (simulating a slow
        // history read); while it is suspended we re-enter processChanges(),
        // which must set changesPending rather than drop the notification. The
        // SECOND read returns the window that landed during the apply — it must
        // be drained and posted, not stranded.
        let firstToken = Data([0x01])
        let secondToken = Data([0x02])
        let store = ScriptableContactStore(outcomes: [
            // First read: empty delta (no post), but it gates so we can re-enter.
            .gatedReturn(ContactChangeSet(changes: [], newToken: firstToken, requiresFullReload: false)),
            // Second (drain) read: the mid-apply window.
            .return(ContactChangeSet(changes: [.updated(localID: "late")], newToken: secondToken, requiresFullReload: false)),
        ])
        let center = NotificationCenter()
        let recorder = Recorder(center: center)
        defer { recorder.stop(center: center) }

        let watcher = ContactChangeWatcher(
            contacts: store,
            cursorStore: cursorStore,
            notificationCenter: center
        )

        // Call A — runs concurrently and parks inside the first changes(since:).
        let callA = Task { @MainActor in await watcher.processChanges() }
        await store.waitUntilParked()

        // Call B arrives WHILE A is suspended. isProcessing is true, so this must
        // set changesPending and return immediately (notification not dropped).
        await watcher.processChanges()

        // Release A's first read; A then drains a SECOND pass for call B's window.
        await store.release()
        await callA.value

        // Exactly two reads happened — one extra drain pass, not zero, not a loop.
        #expect(await store.callCount == 2)
        // The mid-apply window was applied/posted, not stranded.
        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.changeSet?.changes == [.updated(localID: "late")])
        // The cursor advanced to the second (drain) read's token.
        #expect(cursorStore.load() == secondToken)
    }
}

/// A scriptable `ContactStoreProtocol` for watcher tests that need control the
/// real fixtures don't offer: a `changes(since:)` that THROWS on demand, or one
/// that PARKS on a gate so a second `processChanges()` can re-enter mid-flight.
/// Only `changes(since:)` is exercised by `ContactChangeWatcher`; the rest of the
/// protocol is stubbed and must not be called.
actor ScriptableContactStore: ContactStoreProtocol {
    enum Outcome {
        /// Return this change set immediately.
        case `return`(ContactChangeSet)
        /// Park until `release()` is called, then return this change set. Used to
        /// hold the first read open while the test re-enters processChanges().
        case gatedReturn(ContactChangeSet)
        /// Throw, modeling an auth / I-O history-read failure.
        case throwError
    }

    private var outcomes: [Outcome]
    private(set) var callCount = 0

    // Gate plumbing: `parked` resolves when a gated read has suspended; `release`
    // resumes that suspended read.
    private var parkedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    /// Suspends until a gated `changes(since:)` has parked.
    func waitUntilParked() async {
        await withCheckedContinuation { continuation in
            parkedContinuation = continuation
        }
    }

    /// Resumes a parked gated read.
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func changes(since token: Data?) async throws -> ContactChangeSet {
        callCount += 1
        let outcome = outcomes.isEmpty ? Outcome.return(ContactChangeSet(changes: [], newToken: Data(), requiresFullReload: false)) : outcomes.removeFirst()
        switch outcome {
        case .return(let set):
            return set
        case .throwError:
            throw TestStoreError.readFailed
        case .gatedReturn(let set):
            // Signal the test we have parked, then wait for release.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuation = continuation
                parkedContinuation?.resume()
                parkedContinuation = nil
            }
            return set
        }
    }

    enum TestStoreError: Error { case readFailed }

    // MARK: - Unused protocol surface (never called by ContactChangeWatcher)

    func fetchAll() async throws -> [Contact] { unused() }
    func fetch(localID: String) async throws -> Contact? { unused() }
    func save(_ contact: Contact) async throws { unused() }
    func delete(localID: String) async throws { unused() }
    func loadImageData(localID: String) async throws -> Data? { unused() }
    func loadThumbnailImageData(localID: String) async throws -> Data? { unused() }
    func fetchAllGroups() async throws -> [ContactGroup] { unused() }
    func fetchGroup(localID: String) async throws -> ContactGroup? { unused() }
    func createGroup(name: String) async throws -> ContactGroup { unused() }
    func renameGroup(localID: String, to name: String) async throws { unused() }
    func deleteGroup(localID: String) async throws { unused() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { unused() }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { unused() }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { unused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { unused() }

    private func unused() -> Never {
        fatalError("ScriptableContactStore: only changes(since:) is exercised by ContactChangeWatcher")
    }
}
