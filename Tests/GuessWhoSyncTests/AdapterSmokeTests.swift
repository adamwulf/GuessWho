import Testing
@testable import GuessWhoSync

#if canImport(Contacts) && canImport(EventKit)

@Suite("AdapterSmoke")
struct AdapterSmokeTests {
    @Test
    func cnAdapterConformsToContactStoreProtocol() {
        let p: ContactStoreProtocol.Type = CNContactStoreAdapter.self
        _ = p
    }

    @Test
    func ekAdapterConformsToEventStoreProtocol() {
        let p: EventStoreProtocol.Type = EKEventStoreAdapter.self
        _ = p
    }
}

#endif
