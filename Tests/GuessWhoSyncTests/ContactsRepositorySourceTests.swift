import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository — contact sources")
struct ContactsRepositorySourceTests {
    private let iCloud = ContactSource(id: "icloud", name: "iCloud")
    private let google = ContactSource(id: "google", name: "Google")

    @Test @MainActor
    func noSourcesReturnsAnEmptyStoreList() async {
        let store = InMemoryContactStore()
        let repository = ContactsRepository(
            contacts: store,
            notificationCenter: NotificationCenter()
        )

        let sources = await repository.contactSources()

        #expect(sources.isEmpty)
        #expect(sources.count <= 1)
    }

    @Test @MainActor
    func oneSourceReturnsTheSingleStoreSource() async {
        let store = InMemoryContactStore()
        await store.setSources([iCloud])
        let repository = ContactsRepository(
            contacts: store,
            notificationCenter: NotificationCenter()
        )

        let sources = await repository.contactSources()

        #expect(sources == [iCloud])
        #expect(sources.count <= 1)
    }

    @Test @MainActor
    func contactInOneOfTwoSourcesReturnsOnlyItsSource() async {
        let contact = Contact(localID: "ADA", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [contact])
        await store.setSources([iCloud, google])
        await store.setSourceIDs([iCloud.id], forContactLocalID: "ADA")
        let repository = ContactsRepository(
            contacts: store,
            notificationCenter: NotificationCenter()
        )

        let storeSources = await repository.contactSources()
        let recordSources = await repository.sources(for: contact)

        #expect(storeSources == [iCloud, google])
        #expect(recordSources == [iCloud])
    }

    @Test @MainActor
    func unifiedContactSpanningTwoSourcesReturnsBothInStoreOrder() async {
        let contact = Contact(localID: "ADA", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [contact])
        await store.setSources([iCloud, google])
        await store.setSourceIDs([google.id, iCloud.id], forContactLocalID: "ADA")
        let repository = ContactsRepository(
            contacts: store,
            notificationCenter: NotificationCenter()
        )

        let sources = await repository.sources(for: contact)

        #expect(sources == [iCloud, google])
    }

    @Test @MainActor
    func contactWithoutLocalIDReturnsNoSources() async {
        let store = InMemoryContactStore()
        await store.setSources([iCloud, google])
        await store.setSourceIDs([iCloud.id], forContactLocalID: "")
        let repository = ContactsRepository(
            contacts: store,
            notificationCenter: NotificationCenter()
        )

        let sources = await repository.sources(for: Contact(givenName: "Ada"))

        #expect(sources.isEmpty)
    }
}
