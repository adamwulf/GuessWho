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
}
