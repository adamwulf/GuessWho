import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("SingleContactReconciler")
struct SingleContactReconcilerTests {
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)

    private let alpha = "11111111-1111-4111-8111-111111111111"
    private let beta  = "22222222-2222-4222-8222-222222222222"

    private func makeSync(
        contacts: InMemoryContactStore,
        sidecars: InMemorySidecarStore,
        deviceID: String = "device-test"
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: deviceID
        )
    }

    private func guessWhoURLs(in contact: Contact) -> [String] {
        contact.urlAddresses
            .map(\.value)
            .filter { $0.hasPrefix("guesswho://contact/") }
    }

    @Test
    func caseA_assignsFreshUUIDToTargetOnly() throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let bystander = Contact(localID: "OTHER", givenName: "Grace")
        let contacts = InMemoryContactStore(contacts: [target, bystander])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let outcome = try sync.reconcileContactIdentity(localID: "TARGET")

        #expect(outcome.localID == "TARGET")
        #expect(outcome.assignedUUID != nil)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let savedTarget = try #require(try contacts.fetch(localID: "TARGET"))
        let gwURLs = guessWhoURLs(in: savedTarget)
        #expect(gwURLs.count == 1)

        let savedBystander = try #require(try contacts.fetch(localID: "OTHER"))
        #expect(guessWhoURLs(in: savedBystander).isEmpty)
    }

    @Test
    func caseD_mergesLoserSidecarsForTargetOnly() throws {
        let target = Contact(
            localID: "TARGET",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + beta),
                LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha),
            ]
        )
        let contacts = InMemoryContactStore(contacts: [target])
        let sidecars = InMemorySidecarStore()
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            ]),
            at: SidecarKey(kind: .contact, id: alpha)
        )
        try sidecars.write(
            SidecarEnvelope(entityID: beta, fields: [
                "notes": .value(.string("met"), modifiedAt: t1, modifiedBy: "device-B"),
            ]),
            at: SidecarKey(kind: .contact, id: beta)
        )
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        let outcome = try sync.reconcileContactIdentity(localID: "TARGET")

        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs == [beta])
        #expect(outcome.errors.isEmpty)

        let saved = try #require(try contacts.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved) == ["guesswho://contact/" + alpha])

        let winner = try #require(try sidecars.read(SidecarKey(kind: .contact, id: alpha)))
        #expect(Set(winner.fields.keys) == ["nickname", "notes"])

        #expect(try sidecars.read(SidecarKey(kind: .contact, id: beta)) == nil)
    }

    @Test
    func idempotentOnStableContact() throws {
        let url = LabeledValue(label: "GuessWho", value: "guesswho://contact/" + alpha)
        let target = Contact(localID: "TARGET", givenName: "Ada", urlAddresses: [url])
        let contacts = InMemoryContactStore(contacts: [target])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        _ = try sync.reconcileContactIdentity(localID: "TARGET")
        let snapshot = try #require(try contacts.fetch(localID: "TARGET"))

        let outcome = try sync.reconcileContactIdentity(localID: "TARGET")
        #expect(outcome.assignedUUID == nil)
        #expect(outcome.mergedLoserUUIDs.isEmpty)
        #expect(outcome.removedMalformedURLs.isEmpty)
        #expect(outcome.errors.isEmpty)

        let after = try #require(try contacts.fetch(localID: "TARGET"))
        #expect(after == snapshot)
    }

    @Test
    func unknownLocalIDThrowsContactNotFound() throws {
        let contacts = InMemoryContactStore()
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contacts, sidecars: sidecars)

        do {
            _ = try sync.reconcileContactIdentity(localID: "DOES-NOT-EXIST")
            Issue.record("expected throw")
        } catch let error as ContactStoreError {
            switch error {
            case .contactNotFound(let id):
                #expect(id == "DOES-NOT-EXIST")
            }
        }
    }

    // Orphan-sidecar detection requires the global set of carried UUIDs,
    // so the single-contact entry point intentionally returns only the
    // ContactOutcome and never decides whether other UUIDs are orphans.
    // Confirm by leaving an unrelated sidecar in place and showing that
    // reconciling one contact does not delete or report it.
    @Test
    func leavesUnrelatedSidecarsUntouched() throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let contacts = InMemoryContactStore(contacts: [target])
        let sidecars = InMemorySidecarStore()

        let strangerKey = SidecarKey(kind: .contact, id: alpha)
        try sidecars.write(
            SidecarEnvelope(entityID: alpha, fields: [
                "nickname": .value(.string("Stranger"), modifiedAt: t2, modifiedBy: "device-X"),
            ]),
            at: strangerKey
        )

        let sync = makeSync(contacts: contacts, sidecars: sidecars)
        _ = try sync.reconcileContactIdentity(localID: "TARGET")

        #expect(try sidecars.read(strangerKey) != nil)
    }
}
