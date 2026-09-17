import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Package-level coverage for one `Link` (and its note) shared across MORE than
/// two contacts: the `additionalEndpoints` model, the engine multi-endpoint
/// write, corpus/index/reconcile behavior, and the repository projections the
/// UI consumes. Binary links must stay byte-identical and every existing
/// single-contact API must keep working — see `LinkTests` for the binary suite.
@Suite("Multi-contact link — model + engine")
struct MultiContactLinkModelTests {
    private func makeOrchestrator() -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")
        return (sync, sidecars)
    }

    private let contactA = SidecarKey(kind: .contact, id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    private let contactB = SidecarKey(kind: .contact, id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    private let contactC = SidecarKey(kind: .contact, id: "cccccccc-cccc-cccc-cccc-cccccccccccc")
    private let eventX = SidecarKey(kind: .event, id: "11111111-1111-1111-1111-111111111111")
    private let place = SidecarKey(kind: .place, id: "44444444-4444-4444-4444-444444444444")

    // MARK: - endpoints / otherEndpoints helpers

    @Test
    func endpointsAreOrderedAndDistinct() {
        let link = Link(
            id: UUID(),
            endpointA: contactA,
            endpointB: contactB,
            note: "",
            createdAt: Date(),
            modifiedAt: Date(),
            modifiedBy: "d",
            additionalEndpoints: [contactC, contactA]  // contactA duplicates the base slot
        )
        // Distinct, first-appearance order: A, B, C (the duplicate A is dropped).
        #expect(link.endpoints == [contactA, contactB, contactC])
        #expect(link.otherEndpoints(from: contactB) == [contactA, contactC])
        // A non-participant returns all distinct endpoints.
        #expect(link.otherEndpoints(from: eventX) == [contactA, contactB, contactC])
    }

    // MARK: - Engine multi-endpoint write

    @Test
    func addLinkWithEndpointsRoundTripsAllParticipants() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(endpoints: [contactA, contactB, contactC], note: "trio")
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.endpointA == contactA)
        #expect(fetched.endpointB == contactB)
        #expect(fetched.additionalEndpoints == [contactC])
        #expect(fetched.endpoints == [contactA, contactB, contactC])
        #expect(fetched.note == "trio")
    }

    @Test
    func everyParticipantSeesTheSharedLinkExactlyOnce() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(endpoints: [contactA, contactB, contactC], note: "trio")
        for participant in [contactA, contactB, contactC] {
            let atParticipant = try sync.links(at: participant)
            #expect(atParticipant.map(\.id) == [link.id])
        }
    }

    @Test
    func addLinkRejectsFewerThanTwoEndpoints() throws {
        let (sync, _) = makeOrchestrator()
        #expect(throws: EmptyLinkSelectionError.self) {
            _ = try sync.addLink(endpoints: [contactA], note: "solo")
        }
        #expect(throws: EmptyLinkSelectionError.self) {
            _ = try sync.addLink(endpoints: [], note: "none")
        }
    }

    @Test
    func binaryLinkWritesNoAdditionalEndpointsCell() throws {
        // A plain two-endpoint link's envelope must be byte-identical to the
        // pre-feature format: NO additionalEndpoints cell at all.
        let (sync, sidecars) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "binary")
        let envelope = try #require(try sidecars.read(SidecarKey(kind: .link, id: link.id.uuidString)))
        #expect(envelope.fields[Link.additionalEndpointsKey] == nil)
        #expect(link.additionalEndpoints.isEmpty)
    }

    @Test
    func multiLinkWritesAdditionalEndpointsCell() throws {
        let (sync, sidecars) = makeOrchestrator()
        let link = try sync.addLink(endpoints: [contactA, contactB, contactC], note: "trio")
        let envelope = try #require(try sidecars.read(SidecarKey(kind: .link, id: link.id.uuidString)))
        let cell = try #require(envelope.fields[Link.additionalEndpointsKey])
        #expect(cell.value == Link.encodeAdditionalEndpoints([contactC]))
    }

    // MARK: - Counts / projection

    @Test
    func linkCountsCountEachParticipantOnceForAMultiLink() throws {
        let (sync, _) = makeOrchestrator()
        _ = try sync.addLink(endpoints: [contactA, contactB, contactC], note: "trio")
        let counts = try sync.linkCounts(ofKind: .contact)
        #expect(counts[contactA] == 1)
        #expect(counts[contactB] == 1)
        #expect(counts[contactC] == 1)
        #expect(try sync.linkedEndpoints(ofKind: .contact) == Set([contactA, contactB, contactC]))
    }

    @Test
    func multiEndpointEventLinkIsEventEndpointForEveryContact() throws {
        // A group event link: contacts fill endpointA + additional, event is
        // endpointB. Every contact endpoint participates; the event endpoint is
        // the single event of the group.
        let (sync, _) = makeOrchestrator()
        _ = try sync.addLink(endpoints: [contactA, eventX, contactB, contactC], note: "met here")
        #expect(try sync.linkedEndpoints(ofKind: .contact) == Set([contactA, contactB, contactC]))
        #expect(try sync.linkedEndpoints(ofKind: .event) == Set([eventX]))
        for participant in [contactA, contactB, contactC] {
            #expect(try sync.links(at: participant).count == 1)
        }
        #expect(try sync.links(at: eventX).count == 1)
    }

    // MARK: - Envelope decode / backward compatibility

    @Test
    func oldEnvelopeWithoutAdditionalEndpointsDecodesAsBinary() throws {
        // The pre-feature on-disk shape: only endpointA/B/note/createdAt.
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = SidecarEnvelope(entityID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fields: [
            Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(contactA), modifiedAt: when, modifiedBy: "d"),
            Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(contactB), modifiedAt: when, modifiedBy: "d"),
            Link.noteKey: SidecarCell(value: .string("legacy"), modifiedAt: when, modifiedBy: "d"),
            Link.createdAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: when)),
                modifiedAt: when,
                modifiedBy: "d"
            ),
        ])
        let link = try #require(Link(from: envelope))
        #expect(link.additionalEndpoints.isEmpty)
        #expect(link.endpoints == [contactA, contactB])
    }

    @Test
    func envelopeWithAdditionalEndpointsDecodesParticipants() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let later = when.addingTimeInterval(60)
        let envelope = SidecarEnvelope(entityID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fields: [
            Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(contactA), modifiedAt: when, modifiedBy: "d"),
            Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(contactB), modifiedAt: when, modifiedBy: "d"),
            Link.additionalEndpointsKey: SidecarCell(
                value: Link.encodeAdditionalEndpoints([contactC]),
                modifiedAt: later,   // most recent → drives derived modifiedAt/By
                modifiedBy: "z"
            ),
            Link.noteKey: SidecarCell(value: .string("trio"), modifiedAt: when, modifiedBy: "d"),
            Link.createdAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: when)),
                modifiedAt: when,
                modifiedBy: "d"
            ),
        ])
        let link = try #require(Link(from: envelope))
        #expect(link.additionalEndpoints == [contactC])
        // The additionalEndpoints cell is a mutable cell and must feed the
        // derived modifiedAt/modifiedBy max.
        #expect(link.modifiedAt == later)
        #expect(link.modifiedBy == "z")
    }

    @Test
    func malformedAdditionalEndpointsCellFailsWholeLinkDecode() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        func envelope(additionalValue: JSONValue) -> SidecarEnvelope {
            SidecarEnvelope(entityID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fields: [
                Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(contactA), modifiedAt: when, modifiedBy: "d"),
                Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(contactB), modifiedAt: when, modifiedBy: "d"),
                Link.additionalEndpointsKey: SidecarCell(value: additionalValue, modifiedAt: when, modifiedBy: "d"),
                Link.noteKey: SidecarCell(value: .string("x"), modifiedAt: when, modifiedBy: "d"),
                Link.createdAtKey: SidecarCell(
                    value: .string(SidecarISO8601.string(from: when)),
                    modifiedAt: when,
                    modifiedBy: "d"
                ),
            ])
        }
        // Not an array at all.
        #expect(Link(from: envelope(additionalValue: .string("nope"))) == nil)
        // Array containing a non-endpoint element.
        #expect(Link(from: envelope(additionalValue: .array([.string("nope")]))) == nil)
    }

    // MARK: - Codable backward compatibility

    @Test
    func codableOmitsAdditionalEndpointsForBinaryAndDecodesOldPayload() throws {
        let binary = Link(
            id: UUID(),
            endpointA: contactA,
            endpointB: contactB,
            note: "binary",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedBy: "d"
        )
        let data = try JSONEncoder().encode(binary)
        let json = try #require(String(data: data, encoding: .utf8))
        // The old format never had this key; a binary link must not add it.
        #expect(!json.contains("additionalEndpoints"))
        // That very payload IS the old format — it must decode (defaulting []).
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded == binary)
        #expect(decoded.additionalEndpoints.isEmpty)
    }

    @Test
    func codableRoundTripsMultiEndpointLink() throws {
        let multi = Link(
            id: UUID(),
            endpointA: contactA,
            endpointB: contactB,
            note: "trio",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedBy: "d",
            additionalEndpoints: [contactC]
        )
        let data = try JSONEncoder().encode(multi)
        #expect(String(data: data, encoding: .utf8)?.contains("additionalEndpoints") == true)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded == multi)
    }

    // MARK: - Note editing / deletion is shared across participants

    @Test
    func editingTheSharedNoteIsSeenByEveryParticipant() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(endpoints: [contactA, contactB, contactC], note: "old")
        try sync.setLinkNote(id: link.id, note: "new")
        for participant in [contactA, contactB, contactC] {
            let seen = try #require(try sync.links(at: participant).first)
            #expect(seen.id == link.id)
            #expect(seen.note == "new")
        }
    }

    @Test
    func deletingTheSharedLinkRemovesItForEveryParticipant() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(endpoints: [contactA, contactB, contactC], note: "shared")
        try sync.removeLink(id: link.id)
        for participant in [contactA, contactB, contactC] {
            let live = try sync.links(at: participant).filter { $0.deletedAt == nil }
            #expect(live.isEmpty)
        }
    }

    // MARK: - Case-D reconcile rewrites additional endpoints

    @Test
    func caseDRewritesAdditionalEndpoint() async throws {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        let loserUUID = "00000000-0000-0000-0000-000000000002"
        let winnerUUID = "00000000-0000-0000-0000-000000000001"
        var contact = Contact(localID: "local-1")
        contact.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loserUUID),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winnerUUID),
        ]
        try await contacts.save(contact)

        // The loser sits in the ADDITIONAL slot of a three-contact link.
        let loserKey = SidecarKey(kind: .contact, id: loserUUID)
        let link = try sync.addLink(endpoints: [contactA, contactB, loserKey], note: "trio via loser")

        let report = try await sync.reconcileContactIdentities()
        let outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        #expect(outcome.rewrittenLinkIDs == [link.id])

        let rewritten = try #require(try sync.link(id: link.id))
        #expect(rewritten.endpointA == contactA)
        #expect(rewritten.endpointB == contactB)
        #expect(rewritten.additionalEndpoints == [SidecarKey(kind: .contact, id: winnerUUID)])
        // The winner now participates; the corpus re-indexed on the write.
        let atWinner = try await sync.links(at: SidecarKey(kind: .contact, id: winnerUUID))
        #expect(atWinner.map(\.id) == [link.id])
    }

    @Test
    func caseDRewritingBaseAndAdditionalSlotsIsOneWrite() async throws {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = CountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        // One contact collapses two losers L1+L2 onto W. A single link points at
        // L1 (endpointB) AND L2 (additional). Both must rewrite in ONE write and
        // the link is recorded once per distinct loser.
        let loser1 = "00000000-0000-0000-0000-000000000003"
        let loser2 = "00000000-0000-0000-0000-000000000004"
        let winner = "00000000-0000-0000-0000-000000000001"
        var contact = Contact(localID: "local-1")
        contact.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loser1),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loser2),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winner),
        ]
        try await contacts.save(contact)

        let link = try sync.addLink(
            endpoints: [
                contactA,
                SidecarKey(kind: .contact, id: loser1),
                SidecarKey(kind: .contact, id: loser2),
            ],
            note: "straddles two losers"
        )
        let linkKey = SidecarKey(kind: .link, id: link.id.uuidString)
        let writesBefore = sidecars.writeCounts[linkKey] ?? 0

        let report = try await sync.reconcileContactIdentities()
        let outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        #expect(outcome.rewrittenLinkIDs == [link.id])

        let writesAfter = sidecars.writeCounts[linkKey] ?? 0
        #expect(writesAfter - writesBefore == 1)

        let rewritten = try #require(try sync.link(id: link.id))
        let winnerKey = SidecarKey(kind: .contact, id: winner)
        #expect(rewritten.endpointA == contactA)
        #expect(rewritten.endpointB == winnerKey)
        #expect(rewritten.additionalEndpoints == [winnerKey])
    }
}

@Suite("Multi-contact link — repository")
@MainActor
struct MultiContactLinkRepositoryTests {
    private let aUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let bUUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let cUUID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    private func identifiedContact(localID: String, uuid: String) -> Contact {
        Contact(
            localID: localID,
            givenName: localID.uppercased(),
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)")]
        )
    }

    private struct Fixture {
        let repository: ContactsRepository
        let sync: GuessWhoSync
        let contacts: InMemoryContactStore
    }

    private func makeRepository() -> Fixture {
        let center = NotificationCenter()
        let contacts = InMemoryContactStore(contacts: [
            identifiedContact(localID: "a", uuid: aUUID),
            identifiedContact(localID: "b", uuid: bUUID),
            identifiedContact(localID: "c", uuid: cUUID),
        ])
        let sync = GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-A",
            notificationCenter: center
        )
        return Fixture(
            repository: ContactsRepository(contacts: contacts, sync: sync, notificationCenter: center),
            sync: sync,
            contacts: contacts
        )
    }

    private func ids(_ f: Fixture) throws -> (a: ContactID, b: ContactID, c: ContactID) {
        (
            try #require(f.repository.contact(localID: "a")?.contactID),
            try #require(f.repository.contact(localID: "b")?.contactID),
            try #require(f.repository.contact(localID: "c")?.contactID)
        )
    }

    // MARK: - Grouped contact link from every participant

    @Test
    func groupedContactLinkShowsOncePerParticipantWithCoParticipants() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, b, c) = try ids(f)

        let link = try await f.repository.addLink(from: a, to: [b, c], note: "trio")

        for id in [a, b, c] {
            let contactLinks = await f.repository.links(for: id)
            #expect(contactLinks.map(\.id) == [link.id])
            let detail = await f.repository.contactDetailLinks(for: id)
            #expect(detail.contactLinks.map(\.id) == [link.id])
            #expect(detail.eventLinks.isEmpty)
            #expect(detail.placeLinks.isEmpty)
        }

        // Each participant sees the OTHER two, resolved and co-participant-only.
        let othersOfA = f.repository.linkedContacts(of: link, for: a)
        #expect(Set(othersOfA.compactMap { $0?.localID }) == Set(["b", "c"]))
        let othersOfB = f.repository.linkedContacts(of: link, for: b)
        #expect(Set(othersOfB.compactMap { $0?.localID }) == Set(["a", "c"]))
    }

    // MARK: - Grouped event link

    @Test
    func groupedEventLinkClassifiesAsEventForEveryParticipant() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, b, c) = try ids(f)
        let eventUUID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        let link = try await f.repository.addEventLink(for: [a, b, c], eventUUID: eventUUID, note: "met here")

        for id in [a, b, c] {
            let detail = await f.repository.contactDetailLinks(for: id)
            // Single-row ownership: event section only, never the contact section.
            #expect(detail.eventLinks.map(\.id) == [link.id])
            #expect(detail.contactLinks.isEmpty)
            #expect(detail.placeLinks.isEmpty)
            #expect(await f.repository.eventLinks(for: id).map(\.id) == [link.id])
            #expect(f.repository.eventEndpointUUID(of: link, for: id) == eventUUID)
        }

        // All three people surface on the event side.
        let people = f.repository.linkedContacts(of: link, forEventUUID: eventUUID)
        #expect(Set(people.compactMap { $0?.localID }) == Set(["a", "b", "c"]))

        // Co-participants relative to one contact exclude that contact + event.
        let othersOfA = f.repository.linkedContacts(of: link, for: a)
        #expect(Set(othersOfA.compactMap { $0?.localID }) == Set(["b", "c"]))
    }

    // MARK: - Grouped place link

    @Test
    func groupedPlaceLinkClassifiesAsPlaceForEveryParticipant() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, b, c) = try ids(f)
        let placeUUID = "44444444-4444-4444-4444-444444444444"

        let link = try await f.repository.addPlaceLink(for: [a, b, c], placeUUID: placeUUID, note: "hung out")

        for id in [a, b, c] {
            let detail = await f.repository.contactDetailLinks(for: id)
            #expect(detail.placeLinks.map(\.id) == [link.id])
            #expect(detail.contactLinks.isEmpty)
            #expect(detail.eventLinks.isEmpty)
            #expect(await f.repository.placeLinks(for: id).map(\.id) == [link.id])
            #expect(f.repository.linkedPlaceUUID(of: link, for: id) == placeUUID)
        }

        // The place page resolves every participant from the place endpoint.
        let people = f.repository.linkedContacts(of: link, at: SidecarKey(kind: .place, id: placeUUID))
        #expect(Set(people.compactMap { $0?.localID }) == Set(["a", "b", "c"]))
    }

    // MARK: - Dedup + exclude source; empty selection

    @Test
    func addLinkDedupsAndExcludesSource() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, b, _) = try ids(f)

        // b twice + a (the source) — the stored link must be exactly {a, b}.
        let link = try await f.repository.addLink(from: a, to: [b, b, a], note: "deduped")
        #expect(link.endpoints == [
            SidecarKey(kind: .contact, id: aUUID),
            SidecarKey(kind: .contact, id: bUUID),
        ])
        #expect(link.additionalEndpoints.isEmpty)
    }

    @Test
    func addEventLinkDedupsContacts() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, b, _) = try ids(f)
        let eventUUID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        let link = try await f.repository.addEventLink(for: [a, a, b], eventUUID: eventUUID, note: "dedup")
        #expect(link.endpointA == SidecarKey(kind: .contact, id: aUUID))
        #expect(link.endpointB == SidecarKey(kind: .event, id: eventUUID))
        #expect(link.additionalEndpoints == [SidecarKey(kind: .contact, id: bUUID)])
    }

    @Test
    func emptySelectionsAreRejected() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, _, _) = try ids(f)
        let eventUUID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        await #expect(throws: EmptyLinkSelectionError.self) {
            _ = try await f.repository.addLink(from: a, to: [], note: "x")
        }
        // Reduces to empty after excluding the source.
        await #expect(throws: EmptyLinkSelectionError.self) {
            _ = try await f.repository.addLink(from: a, to: [a], note: "x")
        }
        await #expect(throws: EmptyLinkSelectionError.self) {
            _ = try await f.repository.addEventLink(for: [], eventUUID: eventUUID, note: "x")
        }
        await #expect(throws: EmptyLinkSelectionError.self) {
            _ = try await f.repository.addPlaceLink(for: [], placeUUID: "44444444-4444-4444-4444-444444444444", note: "x")
        }
    }

    // MARK: - Shared note edit / delete through the repository

    @Test
    func editingAndDeletingSharedNoteAffectsEveryParticipant() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, b, c) = try ids(f)

        let link = try await f.repository.addLink(from: a, to: [b, c], note: "before")
        try f.repository.setLinkNote(id: link.id, note: "after")
        for id in [a, b, c] {
            let seen = try #require(await f.repository.links(for: id).first)
            #expect(seen.note == "after")
        }

        try f.repository.removeLink(id: link.id)
        for id in [a, b, c] {
            #expect(await f.repository.links(for: id).isEmpty)
        }
    }

    // MARK: - Unresolved participant slot is preserved

    @Test
    func unresolvedParticipantIsPreservedAsNil() async throws {
        let f = makeRepository()
        await f.repository.reload()
        let (a, _, _) = try ids(f)

        // Build a link that includes a contact UUID no cached contact carries.
        let orphan = SidecarKey(kind: .contact, id: "deadbeef-dead-dead-dead-deaddeaddead")
        let link = try f.sync.addLink(
            endpoints: [
                SidecarKey(kind: .contact, id: aUUID),
                SidecarKey(kind: .contact, id: bUUID),
                orphan,
            ],
            note: "one missing"
        )

        let othersOfA = f.repository.linkedContacts(of: link, for: a)
        // Two OTHER participants (b + orphan); orphan resolves to nil but the
        // slot is preserved so the list keeps its shape.
        #expect(othersOfA.count == 2)
        #expect(othersOfA.compactMap { $0?.localID } == ["b"])
        #expect(othersOfA.contains { $0 == nil })
    }
}
