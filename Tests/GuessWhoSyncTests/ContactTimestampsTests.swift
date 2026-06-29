import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Orchestrator-level coverage for the three per-contact timestamp cells:
/// round-trip via `contactTimestamps`/`allContactTimestamps`, and
/// migration-safety (an envelope with no timestamp cells decodes to all-nil,
/// and a stamp write preserves every pre-existing cell). The cells are
/// additive and the schema version is pinned at 1 — these tests guard both.
@Suite("ContactTimestamps")
struct ContactTimestampsTests {
    private func makeOrchestrator() -> (GuessWhoSync, InMemorySidecarStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: events, sidecars: sidecars, deviceID: "device-A")
        return (sync, sidecars)
    }

    private let contact = SidecarKey(kind: .contact, id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

    // MARK: - Round-trip

    @Test
    func stampEachKind_readsBackViaContactTimestamps() throws {
        let (sync, _) = makeOrchestrator()
        let modified = Date(timeIntervalSince1970: 1_000_000)
        let interacted = Date(timeIntervalSince1970: 2_000_000)
        let viewed = Date(timeIntervalSince1970: 3_000_000)

        try sync.stampContactTimestamp(.modified, at: contact, now: modified)
        try sync.stampContactTimestamp(.interacted, at: contact, now: interacted)
        try sync.stampContactTimestamp(.viewed, at: contact, now: viewed)

        let ts = try sync.contactTimestamps(at: contact)
        // ISO8601 round-trips at millisecond precision, so compare on the
        // re-parsed string, not raw Double equality.
        #expect(ts.lastModified == roundTrip(modified))
        #expect(ts.lastInteracted == roundTrip(interacted))
        #expect(ts.lastViewed == roundTrip(viewed))
    }

    @Test
    func allContactTimestamps_keyedByLowercasedGuessWhoID() throws {
        let (sync, _) = makeOrchestrator()
        let other = SidecarKey(kind: .contact, id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let t1 = Date(timeIntervalSince1970: 1_500_000)
        let t2 = Date(timeIntervalSince1970: 2_500_000)

        try sync.stampContactTimestamp(.viewed, at: contact, now: t1)
        try sync.stampContactTimestamp(.modified, at: other, now: t2)

        let all = try sync.allContactTimestamps()
        #expect(all[contact.id]?.lastViewed == roundTrip(t1))
        #expect(all[contact.id]?.lastModified == nil)
        #expect(all[other.id]?.lastModified == roundTrip(t2))
        #expect(all[other.id]?.lastViewed == nil)
    }

    @Test
    func contactTimestamps_onMissingEnvelope_isAllNil() throws {
        let (sync, _) = makeOrchestrator()
        let ts = try sync.contactTimestamps(at: contact)
        #expect(ts == ContactTimestamps())
        #expect(ts.lastModified == nil)
        #expect(ts.lastInteracted == nil)
        #expect(ts.lastViewed == nil)
    }

    // MARK: - Migration-safety

    @Test
    func envelopeWithoutTimestampCells_decodesAllNil() throws {
        // A pre-existing contact envelope carrying only a note cell — no
        // timestamp cells at all — must decode to all-nil timestamps.
        let (sync, sidecars) = makeOrchestrator()
        let noteCell = SidecarCell(value: .string("hi"), modifiedAt: Date(), modifiedBy: "device-A")
        let envelope = SidecarEnvelope(entityID: contact.id, fields: ["note-instance": noteCell])
        try sidecars.write(envelope, at: contact)

        let ts = try sync.contactTimestamps(at: contact)
        #expect(ts == ContactTimestamps())
    }

    @Test
    func stamp_preservesPreExistingCells_andOtherTimestamps() throws {
        // Seed an envelope with an unrelated cell, then stamp ONE timestamp.
        // The unrelated cell must survive, and the other two timestamps stay nil.
        let (sync, sidecars) = makeOrchestrator()
        let preCell = SidecarCell(value: .string("preserve me"), modifiedAt: Date(), modifiedBy: "device-A")
        try sidecars.write(SidecarEnvelope(entityID: contact.id, fields: ["pre": preCell]), at: contact)

        let viewed = Date(timeIntervalSince1970: 4_000_000)
        try sync.stampContactTimestamp(.viewed, at: contact, now: viewed)

        // The pre-existing cell is intact, and schema is still 1, entityID kept.
        let envelope = try #require(try sync.sidecar(at: contact))
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.entityID == contact.id)
        let pre = try #require(envelope.fields["pre"])
        #expect(pre.value == .string("preserve me"))

        // Only the viewed timestamp is populated.
        let ts = try sync.contactTimestamps(at: contact)
        #expect(ts.lastViewed == roundTrip(viewed))
        #expect(ts.lastModified == nil)
        #expect(ts.lastInteracted == nil)
    }

    @Test
    func unparseableTimestampCell_decodesToNil_withoutFailingOthers() throws {
        // A timestamp cell whose value is a non-date string must yield nil for
        // THAT field while a sibling valid timestamp still decodes.
        let (sync, sidecars) = makeOrchestrator()
        let bad = SidecarCell(value: .string("not-a-date"), modifiedAt: Date(), modifiedBy: "device-A")
        let viewed = Date(timeIntervalSince1970: 5_000_000)
        let good = SidecarCell(
            value: .string(SidecarISO8601.string(from: viewed)),
            modifiedAt: viewed,
            modifiedBy: "device-A"
        )
        let envelope = SidecarEnvelope(entityID: contact.id, fields: [
            ContactTimestamps.lastModifiedKey: bad,
            ContactTimestamps.lastViewedKey: good,
        ])
        try sidecars.write(envelope, at: contact)

        let ts = try sync.contactTimestamps(at: contact)
        #expect(ts.lastModified == nil)
        #expect(ts.lastViewed == roundTrip(viewed))
    }

    /// Round-trip a Date through the ISO8601 millisecond encoder so equality
    /// matches what a read-back yields (the on-disk form truncates sub-ms).
    private func roundTrip(_ date: Date) -> Date? {
        SidecarISO8601.date(from: SidecarISO8601.string(from: date))
    }
}
