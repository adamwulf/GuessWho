import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Covers the `SidecarFileWatcher` post path and its wiring into
/// `ContactsRepository`. The live `NSMetadataQuery` half is untestable off a
/// real ubiquity container (`start()` is never called here — the query would
/// silently gather nothing), so tests drive `postSidecarsDidChange` directly,
/// mirroring how `ContactChangeWatcherTests` drives `processChanges()`.
///
/// `@MainActor` because both the watcher and the repository are main-actor
/// isolated. Each test uses its own `NotificationCenter` so posts never cross
/// between tests.
@MainActor
@Suite("SidecarFileWatcher")
struct SidecarFileWatcherTests {
    /// Collects posts of one notification name on an isolated center.
    private final class Recorder {
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
    func postPathPostsOnInjectedCenter() throws {
        let center = NotificationCenter()
        let recorder = Recorder(center: center, name: .guessWhoSidecarsDidChange)
        defer { recorder.stop(center: center) }

        let watcher = SidecarFileWatcher(
            root: FileManager.default.temporaryDirectory,
            notificationCenter: center
        )
        watcher.postSidecarsDidChange(added: 2, changed: 1, removed: 0)

        #expect(recorder.posts.count == 1)
        let post = try #require(recorder.posts.first)
        #expect(post.object as? SidecarFileWatcher === watcher)
    }

    // MARK: - Repository wiring

    @Test
    func sidecarChangePostTriggersOnePresentationOnlyReload() async throws {
        let center = NotificationCenter()
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

        // A burst of watcher posts (one metadata batch = one post each) must
        // collapse into a SINGLE debounced refresh.
        for _ in 0..<3 {
            center.post(name: .guessWhoSidecarsDidChange, object: nil)
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
