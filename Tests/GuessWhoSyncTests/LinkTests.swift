import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Link")
struct LinkTests {
    private func makeOrchestrator() -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")
        return (sync, sidecars)
    }

    private let contactA = SidecarKey(kind: .contact, id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    private let contactB = SidecarKey(kind: .contact, id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    private let eventX = SidecarKey(kind: .event, id: "event-external-id-X")

    // MARK: - API round-trip

    @Test
    func addLinkRoundTrip() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "met")
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.id == link.id)
        #expect(fetched.endpointA == contactA)
        #expect(fetched.endpointB == contactB)
        #expect(fetched.note == "met")
        #expect(fetched.deletedAt == nil)
    }

    @Test
    func linksAtReturnsLinkForBothEndpoints() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "")
        let viaA = try sync.links(at: contactA)
        let viaB = try sync.links(at: contactB)
        #expect(viaA.map(\.id) == [link.id])
        #expect(viaB.map(\.id) == [link.id])
    }

    @Test
    func addLinkNeverDedups() throws {
        let (sync, _) = makeOrchestrator()
        let a = try sync.addLink(from: contactA, to: contactB, note: "note")
        let b = try sync.addLink(from: contactA, to: contactB, note: "note")
        #expect(a.id != b.id)
        let all = try sync.links(at: contactA)
        #expect(Set(all.map(\.id)) == Set([a.id, b.id]))
    }

    @Test
    func setLinkNoteUpdatesNote() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "old")
        try sync.setLinkNote(id: link.id, note: "new")
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.note == "new")
    }

    @Test
    func setLinkNoteOnMissingIsSilentNoOp() throws {
        let (sync, _) = makeOrchestrator()
        try sync.setLinkNote(id: UUID(), note: "x")
        // No error; nothing to fetch.
    }

    @Test
    func removeLinkSoftDeletes() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "n")
        try sync.removeLink(id: link.id)
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.deletedAt != nil)
        #expect(fetched.note == "n") // preserved
    }

    @Test
    func removeLinkPreservesNoteAndEndpoints() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: eventX, note: "kept")
        try sync.removeLink(id: link.id)
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.endpointA == contactA)
        #expect(fetched.endpointB == eventX)
        #expect(fetched.note == "kept")
        #expect(fetched.createdAt == link.createdAt)
    }

    @Test
    func removeLinkOnAlreadyDeletedIsNoOp() throws {
        let (sync, sidecars) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "n")
        try sync.removeLink(id: link.id)
        let snapshot = try #require(try sidecars.read(SidecarKey(kind: .link, id: link.id.uuidString)))
        try sync.removeLink(id: link.id)
        let again = try #require(try sidecars.read(SidecarKey(kind: .link, id: link.id.uuidString)))
        let deletedAtCell1 = try #require(snapshot.fields[Link.deletedAtKey])
        let deletedAtCell2 = try #require(again.fields[Link.deletedAtKey])
        #expect(deletedAtCell1.modifiedAt == deletedAtCell2.modifiedAt)
    }

    @Test
    func setLinkNoteOnSoftDeletedUndeletes() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "old")
        try sync.removeLink(id: link.id)
        try sync.setLinkNote(id: link.id, note: "back")
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.deletedAt == nil)
        #expect(fetched.note == "back")
    }

    @Test
    func linksAtReturnsSoftDeletedLinks() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: contactB, note: "n")
        try sync.removeLink(id: link.id)
        let all = try sync.links(at: contactA)
        #expect(all.count == 1)
        #expect(all[0].deletedAt != nil)
        let live = all.filter { $0.deletedAt == nil }
        #expect(live.isEmpty)
    }

    // MARK: - Cross-kind endpoints

    @Test
    func eventEventLinkRoundTrips() throws {
        let (sync, _) = makeOrchestrator()
        let eventY = SidecarKey(kind: .event, id: "event-Y")
        let link = try sync.addLink(from: eventX, to: eventY, note: "both events")
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.endpointA == eventX)
        #expect(fetched.endpointB == eventY)
    }

    @Test
    func personEventLinkRoundTrips() throws {
        let (sync, _) = makeOrchestrator()
        let link = try sync.addLink(from: contactA, to: eventX, note: "attended")
        let fetched = try #require(try sync.link(id: link.id))
        #expect(fetched.endpointA == contactA)
        #expect(fetched.endpointB == eventX)
    }

    // MARK: - Envelope codec

    @Test
    func linkInitFromEnvelopeFailsOnMissingRequiredCell() throws {
        let envelope = SidecarEnvelope(entityID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fields: [
            Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(contactA), modifiedAt: Date(), modifiedBy: "d"),
            // endpointB intentionally absent
            Link.noteKey: SidecarCell(value: .string("x"), modifiedAt: Date(), modifiedBy: "d"),
            Link.createdAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: Date())),
                modifiedAt: Date(),
                modifiedBy: "d"
            ),
        ])
        #expect(Link(from: envelope) == nil)
    }

    @Test
    func linkInitFromEnvelopeDecodesSoftDeleted() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = SidecarEnvelope(entityID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fields: [
            Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(contactA), modifiedAt: when, modifiedBy: "d"),
            Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(contactB), modifiedAt: when, modifiedBy: "d"),
            Link.noteKey: SidecarCell(value: .string("body"), modifiedAt: when, modifiedBy: "d"),
            Link.createdAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: when)),
                modifiedAt: when,
                modifiedBy: "d"
            ),
            Link.deletedAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: when)),
                modifiedAt: when,
                modifiedBy: "d"
            ),
        ])
        let link = try #require(Link(from: envelope))
        #expect(link.deletedAt != nil)
        #expect(link.note == "body")
    }

    @Test
    func linkInitFromEnvelopeWithNullDeletedAtIsLive() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = SidecarEnvelope(entityID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fields: [
            Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(contactA), modifiedAt: when, modifiedBy: "d"),
            Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(contactB), modifiedAt: when, modifiedBy: "d"),
            Link.noteKey: SidecarCell(value: .string("body"), modifiedAt: when, modifiedBy: "d"),
            Link.createdAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: when)),
                modifiedAt: when,
                modifiedBy: "d"
            ),
            Link.deletedAtKey: SidecarCell(value: .null, modifiedAt: when, modifiedBy: "d"),
        ])
        let link = try #require(Link(from: envelope))
        #expect(link.deletedAt == nil)
    }

    // MARK: - Case-D endpoint rewrite

    @Test
    func caseDRewritesLinkEndpoint() throws {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        // Construct a contact with two GuessWho URLs (Case D).
        let loserUUID = "00000000-0000-0000-0000-000000000002"
        let winnerUUID = "00000000-0000-0000-0000-000000000001"
        var contact = Contact(localID: "local-1")
        contact.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loserUUID),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winnerUUID),
        ]
        try contacts.save(contact)

        // Pre-seed a link whose endpointB points at the loser.
        let third = SidecarKey(kind: .contact, id: "33333333-3333-3333-3333-333333333333")
        let loserKey = SidecarKey(kind: .contact, id: loserUUID)
        let link = try sync.addLink(from: third, to: loserKey, note: "via loser")

        let report = try sync.reconcileContactIdentities()
        let outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        // No loser sidecar exists here (only the contact URL was seeded), so
        // mergedLoserUUIDs stays empty — that field reports loser sidecars
        // that actually merged into the winner. The link rewrite is the
        // invariant under test, and it always runs when Case D collapses URLs.
        #expect(outcome.rewrittenLinkIDs == [link.id])

        let rewritten = try #require(try sync.link(id: link.id))
        #expect(rewritten.endpointA == third)
        #expect(rewritten.endpointB == SidecarKey(kind: .contact, id: winnerUUID))
    }

    @Test
    func caseDRewriteOfBothEndpointsIsOneWrite() throws {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        // Single contact with two GuessWho URLs L1 + L2 collapsing to W.
        // Pre-seed a link with both endpoints pointing at L1 and L2.
        let loser1 = "00000000-0000-0000-0000-000000000003"
        let loser2 = "00000000-0000-0000-0000-000000000004"
        let winner = "00000000-0000-0000-0000-000000000001"
        var contact = Contact(localID: "local-1")
        contact.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loser1),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loser2),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winner),
        ]
        try contacts.save(contact)

        let link = try sync.addLink(
            from: SidecarKey(kind: .contact, id: loser1),
            to: SidecarKey(kind: .contact, id: loser2),
            note: "self-edge through losers"
        )

        let report = try sync.reconcileContactIdentities()
        let outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        // Link appears at most once even though both endpoints were rewritten.
        #expect(outcome.rewrittenLinkIDs == [link.id])

        let rewritten = try #require(try sync.link(id: link.id))
        #expect(rewritten.endpointA == SidecarKey(kind: .contact, id: winner))
        #expect(rewritten.endpointB == SidecarKey(kind: .contact, id: winner))
    }

    @Test
    func caseDDoesNotRewriteOrphanEndpoint() throws {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        // Case D contact (collapse L into W) — link points at an unrelated
        // contact UUID that no live contact carries.
        let loserUUID = "00000000-0000-0000-0000-000000000022"
        let winnerUUID = "00000000-0000-0000-0000-000000000011"
        var contact = Contact(localID: "local-1")
        contact.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loserUUID),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winnerUUID),
        ]
        try contacts.save(contact)

        let orphan = SidecarKey(kind: .contact, id: "deadbeef-dead-dead-dead-deaddeaddead")
        let link = try sync.addLink(from: orphan, to: contactA, note: "orphan endpoint")

        let report = try sync.reconcileContactIdentities()
        let outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        #expect(outcome.rewrittenLinkIDs.isEmpty)
        let untouched = try #require(try sync.link(id: link.id))
        #expect(untouched.endpointA == orphan)
        #expect(untouched.endpointB == contactA)
    }

    @Test
    func multiCaseDOnePassRewritesEachAffectedLinkOnce() throws {
        // Two separate contacts, each in Case D collapsing its own losers.
        // One link straddles the two contacts (endpointA points at contact-1's
        // loser, endpointB points at contact-2's loser). Per §13.4 the link
        // must be rewritten in EXACTLY ONE envelope write across the entire
        // reconcileContactIdentities() pass — not once per contact.
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = CountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        // Per §3.3 Case D, the lex-smaller UUID wins. So winner < loser in
        // hex-string order. Construct the contacts with that invariant.
        let winner1 = "00000000-0000-0000-0000-000000000001"
        let loser1 = "00000000-0000-0000-0000-00000000000a"
        var c1 = Contact(localID: "local-1")
        c1.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loser1),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winner1),
        ]
        try contacts.save(c1)

        let winner2 = "00000000-0000-0000-0000-000000000002"
        let loser2 = "00000000-0000-0000-0000-00000000000b"
        var c2 = Contact(localID: "local-2")
        c2.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loser2),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winner2),
        ]
        try contacts.save(c2)

        // Link straddling L1 and L2.
        let link = try sync.addLink(
            from: SidecarKey(kind: .contact, id: loser1),
            to: SidecarKey(kind: .contact, id: loser2),
            note: "straddler"
        )
        let linkKey = SidecarKey(kind: .link, id: link.id.uuidString)
        let writesToLinkBefore = sidecars.writeCounts[linkKey] ?? 0

        let report = try sync.reconcileContactIdentities()

        // Both contact outcomes carry this link in rewrittenLinkIDs (the same
        // link was touched by both Case Ds).
        let c1Outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        let c2Outcome = try #require(report.contactOutcomes.first { $0.localID == "local-2" })
        #expect(c1Outcome.rewrittenLinkIDs == [link.id])
        #expect(c2Outcome.rewrittenLinkIDs == [link.id])

        // Exactly one envelope write to this link during reconcile, even
        // though two separate Case Ds each touched one of its endpoints.
        let writesToLinkAfter = sidecars.writeCounts[linkKey] ?? 0
        #expect(writesToLinkAfter - writesToLinkBefore == 1)

        // Final state: link's endpoints point at the winners.
        let rewritten = try #require(try sync.link(id: link.id))
        #expect(rewritten.endpointA == SidecarKey(kind: .contact, id: winner1))
        #expect(rewritten.endpointB == SidecarKey(kind: .contact, id: winner2))
    }

    @Test
    func caseDLeavesNonMatchingLinksAlone() throws {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")

        let loserUUID = "00000000-0000-0000-0000-000000000099"
        let winnerUUID = "00000000-0000-0000-0000-000000000088"
        var contact = Contact(localID: "local-1")
        contact.urlAddresses = [
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + loserUUID),
            LabeledValue(label: "GuessWho", value: "guesswho://contact/" + winnerUUID),
        ]
        try contacts.save(contact)

        let unrelated = try sync.addLink(from: contactA, to: contactB, note: "unrelated")

        let report = try sync.reconcileContactIdentities()
        let outcome = try #require(report.contactOutcomes.first { $0.localID == "local-1" })
        #expect(outcome.rewrittenLinkIDs.isEmpty)
        let stillThere = try #require(try sync.link(id: unrelated.id))
        #expect(stillThere.endpointA == contactA)
        #expect(stillThere.endpointB == contactB)
    }
}
