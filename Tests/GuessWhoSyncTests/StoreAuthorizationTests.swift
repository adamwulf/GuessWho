import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Behavioral coverage for the Stage-2 permission API vended by the store
/// adapters (and modeled by the in-memory doubles): the `notDetermined ->
/// request -> authorized` grant, decided-status pass-through, and the
/// thrown-request path that carries a `failureDescription` so the app can
/// restore the `lastError` write it made before permission moved behind the
/// adapters.
@Suite("StoreAuthorization")
struct StoreAuthorizationTests {

    // MARK: - Contacts double

    @Test
    func contactsNotDeterminedGrantsOnRequest() async {
        let store = InMemoryContactStore()
        await store.setAuthorizationStatus(.notDetermined)

        #expect(await store.contactsAuthorizationStatus() == .notDetermined)

        let result = await store.requestContactsAccess()
        #expect(result.status == .authorized)
        #expect(result.failureDescription == nil)
        // The grant is persisted: a follow-up status read reflects it.
        #expect(await store.contactsAuthorizationStatus() == .authorized)
    }

    @Test(arguments: [StoreAuthorizationStatus.denied, .restricted])
    func contactsDecidedStatusPassesThroughUnchanged(_ status: StoreAuthorizationStatus) async {
        let store = InMemoryContactStore()
        await store.setAuthorizationStatus(status)

        let result = await store.requestContactsAccess()
        // A decided store returns its existing verdict; no prompt, no change.
        #expect(result.status == status)
        #expect(result.failureDescription == nil)
        #expect(await store.contactsAuthorizationStatus() == status)
    }

    @Test
    func contactsThrownRequestCarriesFailureDescription() async {
        let store = InMemoryContactStore()
        await store.setAuthorizationStatus(.notDetermined)
        await store.setRequestFailure("Contacts XPC unavailable")

        let result = await store.requestContactsAccess()
        #expect(result.status == .denied)
        #expect(result.failureDescription == "Contacts XPC unavailable")
        // A thrown request leaves the stored status untouched (still undecided).
        #expect(await store.contactsAuthorizationStatus() == .notDetermined)

        // The same `lastError` string SyncService writes from this result.
        let lastError = result.failureDescription.map { "Contacts access request failed: \($0)" }
        #expect(lastError == "Contacts access request failed: Contacts XPC unavailable")
    }

    // MARK: - Events double

    @Test
    func eventsNotDeterminedGrantsOnRequest() async {
        let store = InMemoryEventStore()
        store.setAuthorizationStatus(.notDetermined)

        #expect(store.eventsAuthorizationStatus() == .notDetermined)

        let result = await store.requestEventsAccess()
        #expect(result.status == .authorized)
        #expect(result.failureDescription == nil)
        #expect(store.eventsAuthorizationStatus() == .authorized)
    }

    @Test(arguments: [StoreAuthorizationStatus.denied, .restricted])
    func eventsDecidedStatusPassesThroughUnchanged(_ status: StoreAuthorizationStatus) async {
        let store = InMemoryEventStore()
        store.setAuthorizationStatus(status)

        let result = await store.requestEventsAccess()
        #expect(result.status == status)
        #expect(result.failureDescription == nil)
        #expect(store.eventsAuthorizationStatus() == status)
    }

    @Test
    func eventsThrownRequestCarriesFailureDescription() async {
        let store = InMemoryEventStore()
        store.setAuthorizationStatus(.notDetermined)
        store.setRequestFailure("Calendar daemon timed out")

        let result = await store.requestEventsAccess()
        #expect(result.status == .denied)
        #expect(result.failureDescription == "Calendar daemon timed out")
        #expect(store.eventsAuthorizationStatus() == .notDetermined)

        let lastError = result.failureDescription.map { "Events access request failed: \($0)" }
        #expect(lastError == "Events access request failed: Calendar daemon timed out")
    }
}
