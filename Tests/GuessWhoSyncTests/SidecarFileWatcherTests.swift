import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
@_spi(ConflictReconcile) import GuessWhoSyncTesting

/// Covers the `SidecarFileWatcher` post path and its wiring into
/// `ContactsRepository`. The live `NSMetadataQuery` half is untestable off a
/// real ubiquity container (`start()` is never called here — the query would
/// silently gather nothing), so tests drive the watcher's internal production
/// scheduling and processing entry points directly.
///
/// `@MainActor` because both the watcher and the repository are main-actor
/// isolated. Each test uses its own `NotificationCenter` so posts never cross
/// between tests.
@MainActor
@Suite("SidecarFileWatcher")
struct SidecarFileWatcherTests {
    private func makeSync(sidecars: InMemorySidecarStore = InMemorySidecarStore()) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "watcher-test-device"
        )
    }

    /// Collects posts of one notification name on an isolated center.
    private final class Recorder: @unchecked Sendable {
        private(set) var posts: [Notification] = []
        private var token: NSObjectProtocol?

        init(center: NotificationCenter, name: Notification.Name) {
            token = center.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] note in
                self?.posts.append(note)
            }
        }

        func stop(center: NotificationCenter) {
            if let token { center.removeObserver(token) }
            token = nil
        }
    }

    /// Captures the envelope synchronously at notification delivery time. This
    /// makes the ordering assertion meaningful: it cannot accidentally pass
    /// because the test reads the store only after `processSidecarChanges`
    /// returns. Notification delivery and access happen on the main actor in
    /// these tests; unchecked Sendable is solely for NotificationCenter's
    /// conservatively `@Sendable` observer closure.
    private final class EnvelopeRecorder: @unchecked Sendable {
        private let store: InMemorySidecarStore
        private let key: SidecarKey
        private var token: NSObjectProtocol?
        private(set) var fields: [String: SidecarCell]?

        init(center: NotificationCenter, store: InMemorySidecarStore, key: SidecarKey) {
            self.store = store
            self.key = key
            token = center.addObserver(
                forName: .guessWhoSidecarsDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.fields = try? self.store.read(self.key)?.fields
            }
        }

        func stop(center: NotificationCenter) {
            if let token { center.removeObserver(token) }
            token = nil
        }
    }

    /// Await until `condition` holds or `timeout` elapses. The repository's
    /// sidecar refresh is debounced (300ms trailing), so tests poll rather
    /// than sleep for a fixed guess.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Watcher post path

    @Test
    func changedKeySetReachesSubscribers() async throws {
        let center = NotificationCenter()
        let recorder = Recorder(center: center, name: .guessWhoSidecarsDidChange)
        defer { recorder.stop(center: center) }
        let keys: Set<SidecarKey> = [
            SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440000"),
            SidecarKey(kind: .place, id: "550e8400-e29b-41d4-a716-446655440001"),
        ]

        let watcher = SidecarFileWatcher(
            root: FileManager.default.temporaryDirectory,
            sync: makeSync(),
            notificationCenter: center
        )
        await watcher.processSidecarChanges(
            added: 2,
            changed: 1,
            removed: 0,
            changedKeys: keys
        )

        #expect(recorder.posts.count == 1)
        let post = try #require(recorder.posts.first)
        #expect(post.object as? SidecarFileWatcher === watcher)
        #expect(post.guessWhoSidecarChangeSet.changedKeys == keys)
        #expect(!post.guessWhoSidecarChangeSet.requiresFullRefresh)
    }

    @Test
    func metadataDeliveryBurstCoalescesIntoOnePass() async throws {
        let center = NotificationCenter()
        let recorder = Recorder(center: center, name: .guessWhoSidecarsDidChange)
        defer { recorder.stop(center: center) }
        let watcher = SidecarFileWatcher(
            root: FileManager.default.temporaryDirectory,
            sync: makeSync(),
            notificationCenter: center
        )
        let expectedKeys = Set((0..<8).map {
            SidecarKey(
                kind: .contact,
                id: String(format: "550e8400-e29b-41d4-a716-%012d", $0)
            )
        })

        for key in expectedKeys {
            watcher.scheduleChangeProcessing(
                added: 0,
                changed: 1,
                removed: 0,
                changedKeys: [key]
            )
        }

        await waitUntil { !recorder.posts.isEmpty }
        #expect(recorder.posts.count == 1)
        let post = try #require(recorder.posts.first)
        #expect(post.guessWhoSidecarChangeSet.changedKeys == expectedKeys)

        // Settle beyond another quiet period: no hidden follow-up pass from
        // the same burst may remain queued.
        try? await Task.sleep(for: .milliseconds(700))
        #expect(recorder.posts.count == 1)
    }

    @Test
    func productionChangePathReconcilesBeforePosting() async throws {
        let center = NotificationCenter()
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let key = SidecarKey(kind: .contact, id: "550e8400-e29b-41d4-a716-446655440000")
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_500)
        let current = SidecarEnvelope(entityID: key.id, fields: [
            "current-only": SidecarCell(value: .string("current"), modifiedAt: earlier, modifiedBy: "device-A"),
            "same-cell": SidecarCell(value: .string("old"), modifiedAt: earlier, modifiedBy: "device-A"),
        ])
        let conflict = SidecarEnvelope(entityID: key.id, fields: [
            "conflict-only": SidecarCell(value: .string("conflict"), modifiedAt: earlier, modifiedBy: "device-B"),
            "same-cell": SidecarCell(value: .string("new"), modifiedAt: later, modifiedBy: "device-B"),
        ])
        try store.write(current, at: key)
        store.scriptConflict(at: key, versions: [try JSONEncoder().encode(conflict)])

        let recorder = EnvelopeRecorder(center: center, store: store, key: key)
        defer { recorder.stop(center: center) }

        let watcher = SidecarFileWatcher(
            root: FileManager.default.temporaryDirectory,
            sync: sync,
            notificationCenter: center
        )
        await watcher.processSidecarChanges(added: 0, changed: 1, removed: 0)

        let fields = try #require(recorder.fields)
        #expect(fields.keys.sorted() == ["conflict-only", "current-only", "same-cell"])
        #expect(fields["same-cell"]?.value == .string("new"))
        #expect(try store.keysWithUnresolvedConflicts().isEmpty)
    }

    // MARK: - Repository wiring

    @Test
    func unknownChangedKeysTriggerFullRefreshFallback() async throws {
        let center = NotificationCenter()
        let noNamedKeys = SidecarChangeSet(changedKeys: [])
        #expect(noNamedKeys.requiresFullRefresh)
        let repository = ContactsRepository(
            contacts: InMemoryContactStore(),
            sync: nil,
            favorites: nil,
            notificationCenter: center
        )
        // Registered AFTER construction so the recorder only sees posts the
        // sidecar path produces, never an init-time echo (there is none, but
        // the ordering makes that a non-assumption).
        let recorder = Recorder(center: center, name: .contactsRepositoryDidReload)
        defer { recorder.stop(center: center) }

        // Three posts fired synchronously (the realistic shape: one metadata
        // batch = one post, delivered back-to-back) must collapse into a
        // SINGLE refresh. Precisely: this proves trailing-edge collapse of a
        // SYNCHRONOUS burst — each post cancels the prior pending Task before
        // any debounce timer fires. Debouncing across temporally-SPREAD posts
        // (a second post landing mid-window) rides the same cancel-and-
        // replace path but is not separately exercised here.
        for _ in 0..<3 {
            center.post(
                name: .guessWhoSidecarsDidChange,
                object: nil,
                userInfo: [
                    GuessWhoSidecarsDidChangeKey.changeSet: noNamedKeys
                ]
            )
        }

        await waitUntil { !recorder.posts.isEmpty }
        #expect(recorder.posts.count == 1)

        // Presentation-only: contact records are untouched by a sidecar
        // change, so the post must carry contactDataChanged == false (the
        // photo-cache-preserving contract).
        let post = try #require(recorder.posts.first)
        let dataChanged = post.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool
        #expect(dataChanged == false)

        // Settle past another debounce window: the burst must not produce a
        // trailing second refresh.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(recorder.posts.count == 1)

        _ = repository   // keep the observer alive for the duration
    }
}
