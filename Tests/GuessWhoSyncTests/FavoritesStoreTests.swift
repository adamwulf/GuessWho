import Foundation
import Testing
@testable import GuessWhoSync

@Suite("FavoritesStore")
struct FavoritesStoreTests {
    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-favorites-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func loadAllReturnsEmptyWhenFileMissing() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let items = try store.loadAll()
        #expect(items.isEmpty)
    }

    @Test
    func toggleAddsThenRemoves() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let id = "AB12CD34-0000-0000-0000-000000000001"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let addedState = try store.toggle(kind: .contact, id: id, now: now)
        #expect(addedState == true)
        let afterAdd = try store.loadAll()
        #expect(afterAdd.count == 1)
        #expect(afterAdd[0].kind == .contact)
        // id is lowercased on canonicalization.
        #expect(afterAdd[0].id == id.lowercased())

        let removedState = try store.toggle(kind: .contact, id: id, now: now.addingTimeInterval(1))
        #expect(removedState == false)
        let afterRemove = try store.loadAll()
        #expect(afterRemove.isEmpty)
    }

    @Test
    func groupFavoriteRoundTripsThroughDisk() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        // CNGroup identifiers are mixed-case; the favorite persists it lowercased.
        let id = "F00DCAFE-0000-0000-0000-0000000000AB"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(try store.toggle(kind: .group, id: id, now: now) == true)
        let afterAdd = try store.loadAll()
        #expect(afterAdd.count == 1)
        #expect(afterAdd[0].kind == .group)
        #expect(afterAdd[0].id == id.lowercased())
        // A case-varying lookup still resolves — the store canonicalizes both sides.
        #expect(try store.isFavorite(kind: .group, id: id.uppercased()) == true)

        #expect(try store.toggle(kind: .group, id: id, now: now.addingTimeInterval(1)) == false)
        #expect(try store.loadAll().isEmpty)
    }

    @Test
    func setAllPreservesOrderAcrossReload() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = Favorite(kind: .contact, id: "11111111-1111-1111-1111-111111111111", addedAt: now)
        let b = Favorite(kind: .event,   id: "22222222-2222-2222-2222-222222222222", addedAt: now.addingTimeInterval(1))
        let c = Favorite(kind: .contact, id: "33333333-3333-3333-3333-333333333333", addedAt: now.addingTimeInterval(2))

        try store.setAll([a, b, c])
        let firstRead = try store.loadAll()
        #expect(firstRead.map(\.id) == [a.id, b.id, c.id])

        try store.setAll([c, a, b])
        let reordered = try store.loadAll()
        #expect(reordered.map(\.id) == [c.id, a.id, b.id])
        #expect(reordered.map(\.kind) == [.contact, .contact, .event])
    }

    @Test
    func addedAtRoundTripsThroughISO8601() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FavoritesStore(root: root)
        // Use a value that the fractional-seconds formatter will round-trip
        // exactly: 1.5s after epoch — the formatter emits millisecond
        // precision, so the same value on both sides.
        let when = Date(timeIntervalSince1970: 1_700_000_000.500)
        let id = "44444444-4444-4444-4444-444444444444"
        let favorite = Favorite(kind: .event, id: id, addedAt: when)
        try store.setAll([favorite])

        let reloaded = try store.loadAll()
        #expect(reloaded.count == 1)
        // Encoder writes the ISO8601 string; decoder parses the same
        // string back. The result must equal the value we'd get by
        // round-tripping the input through the formatter — NOT necessarily
        // the original (a Date with sub-ms precision would round).
        let expected = SidecarISO8601.date(from: SidecarISO8601.string(from: when))!
        #expect(reloaded[0].addedAt == expected)
    }

    @Test
    func contactFavoriteMatchesReconciledContactID() {
        let id = "AB12CD34-0000-0000-0000-000000000001"
        let favorite = Favorite(kind: .contact, id: id, addedAt: Date())
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "\(SidecarKey.guessWhoContactURLPrefix)\(id)")
            ]
        )

        #expect(favorite.matches(contact.contactID))
    }

    @Test
    func contactFavoriteDoesNotMatchOtherKindsOrIDs() {
        let id = "ab12cd34-0000-0000-0000-000000000001"
        let otherID = "ab12cd34-0000-0000-0000-000000000002"
        let contact = Contact(
            localID: "local-1",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "\(SidecarKey.guessWhoContactURLPrefix)\(id.uppercased())")
            ]
        )

        #expect(Favorite(kind: .event, id: id, addedAt: Date()).matches(contact.contactID) == false)
        #expect(Favorite(kind: .contact, id: otherID, addedAt: Date()).matches(contact.contactID) == false)
    }

    @Test
    func contactFavoriteDoesNotMatchUnreconciledContactID() {
        let favorite = Favorite(
            kind: .contact,
            id: "ab12cd34-0000-0000-0000-000000000001",
            addedAt: Date()
        )
        let contact = Contact(localID: "local-1")

        #expect(favorite.matches(contact.contactID) == false)
    }
}
