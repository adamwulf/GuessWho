import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("RecentlyLinkedEvents")
struct RecentlyLinkedEventsTests {
    private func makeOrchestrator() -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")
        return (sync, sidecars)
    }

    private let contactA = SidecarKey(kind: .contact, id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    private let contactB = SidecarKey(kind: .contact, id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

    /// Write a link envelope directly (same cell shape as `addLink`) so tests
    /// can pin `createdAt` — sequential `addLink` calls can collide within the
    /// stored millisecond precision, making order assertions flaky.
    @discardableResult
    private func writeLink(
        sidecars: InMemorySidecarStore,
        from a: SidecarKey,
        to b: SidecarKey,
        createdAt: Date,
        deletedAt: Date? = nil
    ) throws -> UUID {
        let id = UUID()
        let key = SidecarKey(kind: .link, id: id.uuidString)
        var fields: [String: SidecarCell] = [
            Link.endpointAKey: SidecarCell(value: Link.encodeEndpoint(a), modifiedAt: createdAt, modifiedBy: "device-A"),
            Link.endpointBKey: SidecarCell(value: Link.encodeEndpoint(b), modifiedAt: createdAt, modifiedBy: "device-A"),
            Link.noteKey: SidecarCell(value: .string(""), modifiedAt: createdAt, modifiedBy: "device-A"),
            Link.createdAtKey: SidecarCell(
                value: .string(SidecarISO8601.string(from: createdAt)),
                modifiedAt: createdAt,
                modifiedBy: "device-A"
            ),
        ]
        if let deletedAt {
            fields[Link.deletedAtKey] = SidecarCell(
                value: .string(SidecarISO8601.string(from: deletedAt)),
                modifiedAt: deletedAt,
                modifiedBy: "device-A"
            )
        }
        try sidecars.write(SidecarEnvelope(schemaVersion: 1, entityID: key.id, fields: fields), at: key)
        return id
    }

    private func makeManualEvent(_ sync: GuessWhoSync, title: String, daysFromNow: Int = 0) throws -> UUID {
        let start = Date().addingTimeInterval(Double(daysFromNow) * 86_400)
        return try sync.createManualEvent(
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            location: nil
        )
    }

    private func eventKey(_ id: UUID) -> SidecarKey {
        SidecarKey(kind: .event, id: id.uuidString)
    }

    // MARK: -

    @Test
    func returnsNewestFirstAndHonorsLimit() throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var ids: [UUID] = []
        for i in 0..<7 {
            let eventID = try makeManualEvent(sync, title: "Event \(i)")
            ids.append(eventID)
            try writeLink(
                sidecars: sidecars,
                from: contactA,
                to: eventKey(eventID),
                createdAt: base.addingTimeInterval(Double(i) * 60)
            )
        }

        let recent = try sync.recentlyLinkedEvents(limit: 5)
        #expect(recent.count == 5)
        // Newest links first: events 6, 5, 4, 3, 2.
        #expect(recent.map(\.id) == [ids[6], ids[5], ids[4], ids[3], ids[2]])
    }

    @Test
    func dedupsRepeatedEventAcrossLinks() throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let shared = try makeManualEvent(sync, title: "Shared")
        let other = try makeManualEvent(sync, title: "Other")
        // Same event linked from two contacts; a distinct older link too.
        try writeLink(sidecars: sidecars, from: contactA, to: eventKey(other), createdAt: base)
        try writeLink(sidecars: sidecars, from: contactA, to: eventKey(shared), createdAt: base.addingTimeInterval(60))
        try writeLink(sidecars: sidecars, from: contactB, to: eventKey(shared), createdAt: base.addingTimeInterval(120))

        let recent = try sync.recentlyLinkedEvents(limit: 5)
        #expect(recent.map(\.id) == [shared, other])
    }

    @Test
    func skipsSoftDeletedLinks() throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let kept = try makeManualEvent(sync, title: "Kept")
        let removed = try makeManualEvent(sync, title: "Removed")
        try writeLink(sidecars: sidecars, from: contactA, to: eventKey(kept), createdAt: base)
        try writeLink(
            sidecars: sidecars,
            from: contactA,
            to: eventKey(removed),
            createdAt: base.addingTimeInterval(60),
            deletedAt: base.addingTimeInterval(120)
        )

        let recent = try sync.recentlyLinkedEvents(limit: 5)
        #expect(recent.map(\.id) == [kept])
    }

    @Test
    func ignoresContactOnlyLinks() throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try writeLink(sidecars: sidecars, from: contactA, to: contactB, createdAt: base)

        let recent = try sync.recentlyLinkedEvents(limit: 5)
        #expect(recent.isEmpty)
    }

    @Test
    func skipsDeletedEventsWithoutConsumingLimit() throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var ids: [UUID] = []
        for i in 0..<3 {
            let eventID = try makeManualEvent(sync, title: "Event \(i)")
            ids.append(eventID)
            try writeLink(
                sidecars: sidecars,
                from: contactA,
                to: eventKey(eventID),
                createdAt: base.addingTimeInterval(Double(i) * 60)
            )
        }
        // Newest-linked event is whole-event-deleted: it must be skipped and
        // the remaining two still returned.
        try sync.deleteEvent(at: eventKey(ids[2]))

        let recent = try sync.recentlyLinkedEvents(limit: 2)
        #expect(recent.map(\.id) == [ids[1], ids[0]])
    }

    @Test
    func eventEndpointOnEitherSideCounts() throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let viaA = try makeManualEvent(sync, title: "Endpoint A")
        let viaB = try makeManualEvent(sync, title: "Endpoint B")
        // Event on endpoint A of one link, endpoint B of the other.
        try writeLink(sidecars: sidecars, from: eventKey(viaA), to: contactA, createdAt: base.addingTimeInterval(60))
        try writeLink(sidecars: sidecars, from: contactA, to: eventKey(viaB), createdAt: base)

        let recent = try sync.recentlyLinkedEvents(limit: 5)
        #expect(recent.map(\.id) == [viaA, viaB])
    }

    @Test
    func zeroOrNegativeLimitReturnsEmpty() throws {
        let (sync, sidecars) = makeOrchestrator()
        let eventID = try makeManualEvent(sync, title: "Event")
        try writeLink(sidecars: sidecars, from: contactA, to: eventKey(eventID), createdAt: Date())
        #expect(try sync.recentlyLinkedEvents(limit: 0).isEmpty)
        #expect(try sync.recentlyLinkedEvents(limit: -1).isEmpty)
    }

    @Test
    func asyncOverloadReturnsRecentlyLinked() async throws {
        let (sync, sidecars) = makeOrchestrator()
        let eventID = try makeManualEvent(sync, title: "Event")
        try writeLink(sidecars: sidecars, from: contactA, to: eventKey(eventID), createdAt: Date())
        let viaAsync = try await sync.recentlyLinkedEvents(limit: 5)
        #expect(viaAsync.map(\.id) == [eventID])
    }

    @Test
    func allLinkedEventsReturnsEveryLinkedEventWithoutAWindowOrLimit() async throws {
        let (sync, sidecars) = makeOrchestrator()
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var linkedIDs: [UUID] = []
        for index in 0..<8 {
            let eventID = try makeManualEvent(sync, title: "Event \(index)", daysFromNow: index * 500)
            linkedIDs.append(eventID)
            try writeLink(
                sidecars: sidecars,
                from: contactA,
                to: eventKey(eventID),
                createdAt: base.addingTimeInterval(Double(index))
            )
        }
        _ = try makeManualEvent(sync, title: "Unlinked", daysFromNow: -5_000)

        let all = try await sync.allLinkedEvents()
        #expect(Set(all.map(\.id)) == Set(linkedIDs))
    }
}
