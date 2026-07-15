import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository — group favorites projection")
struct ContactsRepositoryGroupFavoritesTests {
    @Test @MainActor
    func favoriteListItemsResolvesGroupFavoriteAgainstCache() async throws {
        let store = InMemoryContactStore()
        let family = try await store.createGroup(name: "Family")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        let favorite = Favorite(kind: .group, id: family.localID, addedAt: Date())
        let items = repository.favoriteListItems(from: [favorite]) { _ in nil }

        #expect(items.count == 1)
        #expect(items[0].kind == .group)
        #expect(items[0].group?.localID == family.localID)
        #expect(items[0].group?.name == "Family")
    }

    @Test @MainActor
    func favoriteListItemsLeavesUnknownGroupUnresolved() async {
        // No matching group in the cache → the row projects `group: nil`, which
        // the Favorites list renders as "Unavailable".
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let favorite = Favorite(kind: .group, id: "no-such-group", addedAt: Date())

        let items = repository.favoriteListItems(from: [favorite]) { _ in nil }

        #expect(items.count == 1)
        #expect(items[0].kind == .group)
        #expect(items[0].group == nil)
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
}
