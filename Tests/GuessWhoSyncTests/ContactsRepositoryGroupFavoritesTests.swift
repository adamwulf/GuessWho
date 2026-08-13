import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository — group favorites projection")
struct ContactsRepositoryGroupFavoritesTests {
    // MARK: - Projection against the cache (pure, no favorites store)

    @Test @MainActor
    func favoriteListItemsResolvesGroupFavoriteAgainstCache() async throws {
        let store = InMemoryContactStore()
        let family = try await store.createGroup(name: "Family")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        let favorite = Favorite(kind: .group, id: family.localID, addedAt: Date())
        let items = repository.favoriteListItems(from: [favorite]) { _ in nil }

        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.kind == .group)
        #expect(item.group?.localID == family.localID)
        #expect(item.group?.name == "Family")
    }

    @Test @MainActor
    func favoriteListItemsLeavesUnknownGroupUnresolved() async {
        // No matching group in the cache → the row projects `group: nil`, which
        // the Favorites list renders as "Unavailable".
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let favorite = Favorite(kind: .group, id: "no-such-group", addedAt: Date())

        let items = repository.favoriteListItems(from: [favorite]) { _ in nil }

        guard let item = items.first else {
            Issue.record("expected the unresolved favorite projection")
            return
        }
        #expect(items.count == 1)
        #expect(item.kind == .group)
        #expect(item.group == nil)
    }

    @Test @MainActor
    func groupLookupIsCaseInsensitive() async throws {
        let store = InMemoryContactStore()
        let group = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        // Favorites persist the localID lowercased; the lookup must still match a
        // mixed/upper-case query against the stored `CNGroup.identifier`.
        #expect(repository.group(localID: group.localID.uppercased())?.localID == group.localID)
        #expect(repository.group(localID: "missing") == nil)
    }

    // MARK: - isGroupFavorite / setGroupFavorite against a REAL on-disk store
    //
    // These exercise the production `ContactsRepository.isGroupFavorite` /
    // `setGroupFavorite` over a REAL on-disk `FavoritesStore` — the same store
    // the app wires and the same store the MCP group favorite tools read. No
    // canonicalization, idempotency, or persistence is re-implemented here; the
    // tests only seed/inspect through the real store and assert its behavior.

    @Test @MainActor
    func setGroupFavoritePersistsCanonicalLowercasedKey() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let repository = makeRepository(favorites: store)
        // `CNGroup.identifier` values are mixed-case; the persisted favorite key
        // must be the lowercased local id — production canonicalization.
        let group = ContactGroup(localID: "CNGroup-UPPER-ABC", name: "Work")

        #expect(try repository.setGroupFavorite(true, for: group) == true)
        #expect(repository.isGroupFavorite(group) == true)

        let stored = try store.loadAll()
        let persisted = try #require(stored.first)
        #expect(stored.count == 1)
        #expect(persisted.kind == .group)
        #expect(persisted.id == "cngroup-upper-abc")
        // The raw mixed-case Contacts identifier is never what lands on disk.
        #expect(persisted.id != group.localID)
    }

    @Test @MainActor
    func setGroupFavoriteIdempotentTrueDoesNotRewriteFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let repository = makeRepository(favorites: store)
        let group = ContactGroup(localID: "in-memory-group-1", name: "Work")

        #expect(try repository.setGroupFavorite(true, for: group) == true)
        let before = try fileSnapshot(store.fileURL)

        // Already favorited: an idempotent set returns the current state and
        // performs NO write. The early-return lives in production, not this test.
        #expect(try repository.setGroupFavorite(true, for: group) == true)

        let after = try fileSnapshot(store.fileURL)
        #expect(after == before) // bytes, date, and inode unchanged → no replacement
        #expect(try store.loadAll().filter { $0.kind == .group }.count == 1)
    }

    @Test @MainActor
    func groupFavoriteSharesGenericStoreState() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let repository = makeRepository(favorites: store)
        let group = ContactGroup(localID: "in-memory-group-7", name: "Work")

        // A repository write is visible to the generic store...
        #expect(try repository.setGroupFavorite(true, for: group) == true)
        #expect(try store.isFavorite(kind: .group, id: group.localID) == true)
        #expect(try store.loadAll().contains { $0.kind == .group && $0.id == group.localID })

        // ...and a generic-store clear is visible to the repository — one store,
        // one canonical key, shared by the group-specific and generic surfaces.
        #expect(try store.set(kind: .group, id: group.localID, favorite: false, now: Date()) == true)
        #expect(repository.isGroupFavorite(group) == false)
    }

    @Test @MainActor
    func setGroupFavoriteFalseClearsPersistedRow() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let repository = makeRepository(favorites: store)
        let group = ContactGroup(localID: "in-memory-group-3", name: "Work")

        #expect(try repository.setGroupFavorite(true, for: group) == true)
        #expect(try repository.setGroupFavorite(false, for: group) == false)
        #expect(repository.isGroupFavorite(group) == false)
        #expect(try store.loadAll().contains { $0.kind == .group } == false)
    }

    @Test @MainActor
    func repeatedGroupFavoriteClearIsANoWrite() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let repository = makeRepository(favorites: store)
        let group = ContactGroup(localID: "in-memory-group-9", name: "Work")

        // Establish the file (favorite then clear) so a subsequent no-write is
        // observable against a file that actually exists.
        #expect(try repository.setGroupFavorite(true, for: group) == true)
        #expect(try repository.setGroupFavorite(false, for: group) == false)
        let before = try fileSnapshot(store.fileURL)

        // Already cleared: the repeated clear returns the current state and
        // writes nothing.
        #expect(try repository.setGroupFavorite(false, for: group) == false)

        let after = try fileSnapshot(store.fileURL)
        #expect(after == before)
    }

    // MARK: - Helpers

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-repo-groupfav-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    private func makeRepository(favorites: FavoritesStore) -> ContactsRepository {
        // A fresh NotificationCenter isolates this repository's observers from any
        // other repository sharing `.default` in a parallel test.
        ContactsRepository(
            contacts: InMemoryContactStore(),
            favorites: favorites,
            notificationCenter: NotificationCenter())
    }

    /// The on-disk bytes, modification date, and inode of a file. Production
    /// writes replace the file atomically, so the inode makes a same-content
    /// rewrite observable even when the filesystem timestamp resolution does not.
    private struct FileSnapshot: Equatable {
        let bytes: Data
        let modificationDate: Date?
        let systemFileNumber: UInt64?
    }

    private func fileSnapshot(_ url: URL) throws -> FileSnapshot {
        let bytes = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileSnapshot(
            bytes: bytes,
            modificationDate: attributes[.modificationDate] as? Date,
            systemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
