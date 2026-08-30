import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Contact detail link optimization")
struct ContactDetailLinkOptimizationTests {
    private let contactAUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let contactBUUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func identifiedContact(localID: String, uuid: String) -> Contact {
        Contact(
            localID: localID,
            givenName: localID.uppercased(),
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)")
            ]
        )
    }

    @MainActor
    private func makeRepository(
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (
        repository: ContactsRepository,
        sync: GuessWhoSync,
        contacts: InMemoryContactStore,
        sidecars: ScanCountingSidecarStore,
        notificationCenter: NotificationCenter
    ) {
        let contacts = InMemoryContactStore(contacts: [
            identifiedContact(localID: "a", uuid: contactAUUID),
            identifiedContact(localID: "b", uuid: contactBUUID),
        ])
        let sidecars = ScanCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-A",
            notificationCenter: notificationCenter
        )
        return (
            ContactsRepository(
                contacts: contacts,
                sync: sync,
                notificationCenter: notificationCenter
            ),
            sync,
            contacts,
            sidecars,
            notificationCenter
        )
    }

    @Test @MainActor
    func oneContactDetailSnapshotEnumeratesLinkCorpusOnceAndWarmsOtherContacts() async throws {
        let fixture = makeRepository()
        let contactA = SidecarKey(kind: .contact, id: contactAUUID)
        let contactB = SidecarKey(kind: .contact, id: contactBUUID)
        _ = try fixture.sync.addLink(from: contactA, to: contactB, note: "contact")
        _ = try fixture.sync.addLink(
            from: contactA,
            to: SidecarKey(kind: .event, id: "event-a"),
            note: "event"
        )
        await fixture.repository.reload()

        let idA = try #require(fixture.repository.contact(localID: "a")?.contactID)
        let idB = try #require(fixture.repository.contact(localID: "b")?.contactID)
        let enumerationsBefore = fixture.sidecars.allKeysCount

        let first = await fixture.repository.contactDetailLinks(for: idA)
        #expect(first.contactLinks.count == 1)
        #expect(first.eventLinks.count == 1)
        #expect(fixture.sidecars.allKeysCount == enumerationsBefore + 1)

        _ = await fixture.repository.contactDetailLinks(for: idB)
        #expect(fixture.sidecars.allKeysCount == enumerationsBefore + 1)
    }

    @Test @MainActor
    func fusedSnapshotIsIdenticalToOriginalReadsAcrossFilteringAndDirectionCases() async throws {
        let fixture = makeRepository()
        let contactA = SidecarKey(kind: .contact, id: contactAUUID)
        let contactB = SidecarKey(kind: .contact, id: contactBUUID)
        let eventA = SidecarKey(kind: .event, id: "event-a")
        let eventB = SidecarKey(kind: .event, id: "event-b")
        let place = SidecarKey(kind: .place, id: "place-a")

        let contactForward = try fixture.sync.addLink(from: contactA, to: contactB, note: "forward")
        let contactReverse = try fixture.sync.addLink(from: contactB, to: contactA, note: "reverse")
        let eventForward = try fixture.sync.addLink(from: contactA, to: eventA, note: "event forward")
        let eventReverse = try fixture.sync.addLink(from: eventB, to: contactA, note: "event reverse")
        _ = try fixture.sync.addLink(from: contactA, to: place, note: "other kind")
        let deletedContact = try fixture.sync.addLink(from: contactA, to: contactB, note: "deleted contact")
        let deletedEvent = try fixture.sync.addLink(from: eventA, to: contactA, note: "deleted event")
        try fixture.sync.removeLink(id: deletedContact.id)
        try fixture.sync.removeLink(id: deletedEvent.id)

        let malformedID = UUID()
        try fixture.sidecars.write(
            SidecarEnvelope(entityID: malformedID.uuidString, fields: [:]),
            at: SidecarKey(kind: .link, id: malformedID.uuidString)
        )

        await fixture.repository.reload()
        let idA = try #require(fixture.repository.contact(localID: "a")?.contactID)

        let originalContactLinks = await fixture.repository.links(for: idA)
        let originalEventLinks = await fixture.repository.eventLinks(for: idA)
        let fused = await fixture.repository.contactDetailLinks(for: idA)

        #expect(fused.contactLinks == originalContactLinks)
        #expect(fused.eventLinks == originalEventLinks)
        #expect(Set(fused.contactLinks.map(\.id)) == Set([contactForward.id, contactReverse.id]))
        #expect(Set(fused.eventLinks.map(\.id)) == Set([eventForward.id, eventReverse.id]))
        #expect(
            Set(fused.eventLinks.compactMap { fixture.repository.eventEndpointUUID(of: $0, for: idA) })
                == Set([eventA.id, eventB.id])
        )
    }

    @Test @MainActor
    func localLinkAddAndRemoveInvalidateBeforeTheNextRead() async throws {
        let fixture = makeRepository()
        await fixture.repository.reload()
        let idA = try #require(fixture.repository.contact(localID: "a")?.contactID)
        let idB = try #require(fixture.repository.contact(localID: "b")?.contactID)

        let empty = await fixture.repository.contactDetailLinks(for: idA)
        #expect(empty.contactLinks.isEmpty)
        let enumerationsAfterWarm = fixture.sidecars.allKeysCount

        let added = try await fixture.repository.addLink(from: idA, to: idB, note: "new")
        let afterAdd = await fixture.repository.contactDetailLinks(for: idA)
        #expect(afterAdd.contactLinks.map(\.id) == [added.id])
        #expect(fixture.sidecars.allKeysCount == enumerationsAfterWarm + 1)

        try fixture.repository.removeLink(id: added.id)
        let afterRemove = await fixture.repository.contactDetailLinks(for: idA)
        #expect(afterRemove.contactLinks.isEmpty)
        #expect(fixture.sidecars.allKeysCount == enumerationsAfterWarm + 2)
    }

    @Test @MainActor
    func watcherLinkAndUnknownChangesInvalidateWhileNonLinkChangeStaysWarm() async throws {
        let center = NotificationCenter()
        let fixture = makeRepository(notificationCenter: center)
        await fixture.repository.reload()
        let idA = try #require(fixture.repository.contact(localID: "a")?.contactID)
        let contactA = SidecarKey(kind: .contact, id: contactAUUID)
        let contactB = SidecarKey(kind: .contact, id: contactBUUID)

        _ = await fixture.repository.contactDetailLinks(for: idA)
        let enumerationsAfterWarm = fixture.sidecars.allKeysCount

        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [
                GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [contactA])
            ]
        )
        _ = await fixture.repository.contactDetailLinks(for: idA)
        #expect(fixture.sidecars.allKeysCount == enumerationsAfterWarm)

        let remoteSync = GuessWhoSync(
            contacts: fixture.contacts,
            events: InMemoryEventStore(),
            sidecars: fixture.sidecars,
            deviceID: "device-B",
            notificationCenter: NotificationCenter()
        )
        let remoteLink = try remoteSync.addLink(from: contactB, to: contactA, note: "remote")

        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [
                GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(
                    changedKeys: [SidecarKey(kind: .link, id: remoteLink.id.uuidString)]
                )
            ]
        )
        let afterNamedLink = await fixture.repository.contactDetailLinks(for: idA)
        #expect(afterNamedLink.contactLinks.map(\.id) == [remoteLink.id])
        #expect(fixture.sidecars.allKeysCount == enumerationsAfterWarm + 1)

        _ = try remoteSync.addLink(
            from: contactA,
            to: SidecarKey(kind: .event, id: "remote-event"),
            note: "remote unknown-scope"
        )
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [
                GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet.fullRefresh
            ]
        )
        let afterUnknown = await fixture.repository.contactDetailLinks(for: idA)
        #expect(afterUnknown.eventLinks.count == 1)
        #expect(fixture.sidecars.allKeysCount == enumerationsAfterWarm + 2)
    }
}
