import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Mail activities as stored cells on the contact envelope: the model's
/// Message-ID identity, the engine's one-write record of activity plus
/// `lastInteracted`, and the forward-compatibility contract
/// (docs/sidecar-compatibility.md) — every other cell survives the write.
@Suite("Mail activity storage")
struct MailActivityTests {
    private let key = SidecarKey(kind: .contact, id: "22222222-2222-2222-2222-222222222222")

    private func makeSync(_ sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-mail"
        )
    }

    private func activity(
        _ messageID: String,
        receivedAt: Date,
        subject: String? = "Lunch?",
        mailURL: String? = nil
    ) throws -> MailActivity {
        try #require(MailActivity(
            senderAddress: " ada@example.com ",
            subject: subject,
            receivedAt: receivedAt,
            messageID: messageID,
            mailURL: mailURL
        ))
    }

    /// The four stored parts of a cell (SidecarCell is not Equatable).
    private func expectSameCell(_ lhs: SidecarCell?, _ rhs: SidecarCell?) throws {
        let lhs = try #require(lhs)
        let rhs = try #require(rhs)
        #expect(lhs.value == rhs.value)
        #expect(lhs.modifiedAt == rhs.modifiedAt)
        #expect(lhs.modifiedBy == rhs.modifiedBy)
        #expect(lhs.deletedAt == rhs.deletedAt)
    }

    /// Writes `cells` straight into the envelope at `key`, as another build
    /// or device would, keeping every other cell.
    private func seed(_ cells: [String: SidecarCell], in sidecars: InMemorySidecarStore) throws {
        let envelope = try sidecars.read(key)
        let fields = (envelope?.fields ?? [:]).merging(cells) { _, new in new }
        try sidecars.write(SidecarEnvelope(entityID: envelope?.entityID ?? key.id, fields: fields), at: key)
    }

    /// A live cell holding `value`, stamped by another device.
    private func foreignCell(_ value: JSONValue, deletedAt: Date? = nil) -> SidecarCell {
        SidecarCell(
            value: value,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedBy: "other-device",
            deletedAt: deletedAt
        )
    }

    /// `count` activities received one second apart, oldest first.
    private func activities(_ count: Int, from start: Date, prefix: String) throws -> [MailActivity] {
        try (0..<count).map { index in
            try activity("<\(prefix)-\(index)@example.com>", receivedAt: start.addingTimeInterval(TimeInterval(index)))
        }
    }

    // MARK: - Model

    @Test
    func messageIDSpellingsShareOneIdentity() throws {
        let received = Date(timeIntervalSince1970: 1_790_000_000)
        let bracketed = try activity("<abc.123@Example.COM>", receivedAt: received)
        let bare = try activity("  abc.123@example.com ", receivedAt: received)
        let folded = try activity("<abc.123@\r\n example.com>", receivedAt: received)

        #expect(bracketed.messageID == "abc.123@example.com")
        #expect(bracketed.id == bare.id)
        #expect(bracketed.id == folded.id)
        #expect(MailActivity.activityID(forMessageID: "<abc.123@example.com>") == bracketed.id)
        #expect(bracketed.senderAddress == "ada@example.com")

        // The local part keeps its case, so a different local part is a
        // different message.
        let otherCase = try activity("<ABC.123@example.com>", receivedAt: received)
        #expect(otherCase.id != bracketed.id)
    }

    @Test
    func emptyMessageIDHasNoIdentity() {
        for raw in ["", "   ", "<>", "< \r\n >"] {
            #expect(MailActivity.activityID(forMessageID: raw) == nil)
            #expect(MailActivity(
                senderAddress: "ada@example.com",
                subject: nil,
                receivedAt: Date(),
                messageID: raw
            ) == nil)
        }
    }

    // MARK: - Engine

    @Test
    func recordThenReadRoundTrips() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        // Sub-millisecond input: the model rounds to stored precision, so the
        // read-back value is EQUAL to the one written.
        let full = try activity(
            "<one@example.com>",
            receivedAt: Date(timeIntervalSince1970: 1_790_000_000.123456),
            mailURL: "message://%3Cone@example.com%3E"
        )
        let bare = try activity(
            "<two@example.com>",
            receivedAt: Date(timeIntervalSince1970: 1_780_000_000),
            subject: nil
        )

        try sync.recordMailActivity(full, at: key)
        try sync.recordMailActivity(bare, at: key)

        #expect(try sync.mailActivities(at: key) == [full, bare])

        // Serialization leg: the envelope survives the production codec and
        // decodes back to the same activities.
        let envelope = try #require(try sidecars.read(key))
        let data = try SidecarEnvelopeCodec.encode(envelope)
        let decoded = try JSONDecoder().decode(SidecarEnvelope.self, from: data)
        #expect(decoded.cellsDroppedOnDecode == 0)
        let fromJSON = try #require(decoded.fields[full.cellKey])
        #expect(MailActivity(cellKey: full.cellKey, cell: fromJSON) == full)
        let bareFromJSON = try #require(decoded.fields[bare.cellKey])
        #expect(MailActivity(cellKey: bare.cellKey, cell: bareFromJSON) == bare)
    }

    @Test
    func duplicateDeliveryIsANoOp() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let message = try activity("<dup@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))

        let first = try sync.recordMailActivity(message, at: key)
        #expect(first.didWrite)
        let afterFirst = try #require(try sidecars.read(key))

        let second = try sync.recordMailActivity(message, at: key)
        #expect(second == MailActivityWriteOutcome(
            activityChanged: false,
            prunedActivityCount: 0,
            lastInteractedChanged: false,
            lastInteracted: message.receivedAt
        ))
        let afterSecond = try #require(try sidecars.read(key))
        try expectSameCell(afterSecond.fields[message.cellKey], afterFirst.fields[message.cellKey])
        #expect(try sync.mailActivities(at: key) == [message])
    }

    @Test
    func redeliveryWithChangedPayloadUpsertsTheSameCell() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let received = Date(timeIntervalSince1970: 1_790_000_000)
        let original = try activity("<edit@example.com>", receivedAt: received, subject: nil)
        let updated = try activity("edit@EXAMPLE.com", receivedAt: received, subject: "Now with a subject")
        #expect(original.id == updated.id)

        try sync.recordMailActivity(original, at: key)
        let outcome = try sync.recordMailActivity(updated, at: key)

        #expect(outcome.activityChanged)
        #expect(!outcome.lastInteractedChanged)
        #expect(try sync.mailActivities(at: key) == [updated])
    }

    @Test
    func recordPreservesEveryOtherCell() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        // A note, a stamp, and two cells from a newer build: a UUID-keyed cell
        // with an unknown inner type and a fixed-key cell this build never
        // reads.
        let noteID = try sync.addNote(at: key, body: "met at WWDC")
        try sync.stampContactTimestamp(.viewed, at: key, now: stamp)
        let unknownID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let seeded = try #require(try sidecars.read(key))
        var fields = seeded.fields
        fields[unknownID.uuidString] = SidecarCell(
            value: .object([
                SidecarField.innerFieldKey: .string("source"),
                SidecarField.innerTypeKey: .string("type_from_the_future"),
                SidecarField.innerValueKey: .string("x"),
            ]),
            modifiedAt: stamp,
            modifiedBy: "future-device"
        )
        fields["futureCell"] = SidecarCell(
            value: .object(["futureKey": .string("keep me")]),
            modifiedAt: stamp,
            modifiedBy: "future-device"
        )
        try sidecars.write(SidecarEnvelope(entityID: seeded.entityID, fields: fields), at: key)
        let before = try #require(try sidecars.read(key))
        // `fields(at:)` order is unspecified; compare in a fixed order.
        func sortedFields() throws -> [SidecarField] {
            try sync.fields(at: key).sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let fieldsBefore = try sortedFields()

        let message = try activity("<keep@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try sync.recordMailActivity(message, at: key)

        // Every pre-existing cell is untouched; exactly two cells were added
        // (the activity and lastInteracted).
        let after = try #require(try sidecars.read(key))
        #expect(after.entityID == before.entityID)
        for (cellKey, cell) in before.fields {
            try expectSameCell(after.fields[cellKey], cell)
        }
        #expect(Set(after.fields.keys).subtracting(before.fields.keys)
            == [message.cellKey, ContactTimestamps.lastInteractedKey])

        // The activity stays out of the field-instance views.
        #expect(try sortedFields() == fieldsBefore)
        #expect(try sync.notes(at: key).map(\.id) == [noteID])

        // And an ordinary field write (the raw read-modify-write an older
        // build also does) carries the activity cell through untouched.
        let activityCell = after.fields[message.cellKey]
        try sync.addField(at: key, field: "nickname", type: .note, value: .string("Ada"))
        try expectSameCell(try sidecars.read(key)?.fields[message.cellKey], activityCell)
        #expect(try sync.mailActivities(at: key) == [message])
    }

    @Test
    func lastInteractedMovesForwardToReceivedTimeOnly() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let t1 = Date(timeIntervalSince1970: 1_790_000_000)
        let t2 = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try sync.recordMailActivity(try activity("<t1@example.com>", receivedAt: t1), at: key)
        #expect(first.lastInteractedChanged)
        #expect(first.lastInteracted == t1)
        #expect(try sync.contactTimestamps(at: key).lastInteracted == t1)
        // The cell's modifiedAt is the received time, not the write time.
        let cell = try #require(try sidecars.read(key)?.fields[ContactTimestamps.lastInteractedKey])
        #expect(cell.modifiedAt == t1)
        #expect(cell.modifiedBy == "device-mail")

        // An older message processed late records the activity but never
        // rewinds lastInteracted.
        let older = try sync.recordMailActivity(try activity("<t0@example.com>", receivedAt: t0), at: key)
        #expect(older.activityChanged)
        #expect(!older.lastInteractedChanged)
        #expect(older.lastInteracted == t1)
        #expect(try sync.contactTimestamps(at: key).lastInteracted == t1)

        let newer = try sync.recordMailActivity(try activity("<t2@example.com>", receivedAt: t2), at: key)
        #expect(newer.lastInteractedChanged)
        #expect(try sync.contactTimestamps(at: key).lastInteracted == t2)
    }

    @Test
    func readsNewestFirstAndSkipsDeletedCells() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let middle = try activity("<b@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let oldest = try activity("<a@example.com>", receivedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let newest = try activity("<c@example.com>", receivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let removed = try activity("<gone@example.com>", receivedAt: Date(timeIntervalSince1970: 1_810_000_000))
        for message in [middle, oldest, newest, removed] {
            try sync.recordMailActivity(message, at: key)
        }

        // Tombstone one cell, as a build with a delete action would.
        let envelope = try #require(try sidecars.read(key))
        var fields = envelope.fields
        let live = try #require(fields[removed.cellKey])
        let deletedAt = Date(timeIntervalSince1970: 1_820_000_000)
        fields[removed.cellKey] = SidecarCell(
            value: live.value, modifiedAt: deletedAt, modifiedBy: "other-device", deletedAt: deletedAt)
        try sidecars.write(SidecarEnvelope(entityID: envelope.entityID, fields: fields), at: key)

        #expect(try sync.mailActivities(at: key) == [newest, middle, oldest])

        // A repeat delivery does not bring the deleted activity back.
        let outcome = try sync.recordMailActivity(removed, at: key)
        #expect(!outcome.activityChanged)
        #expect(try sidecars.read(key)?.fields[removed.cellKey]?.deletedAt == deletedAt)
        #expect(try sync.mailActivities(at: key) == [newest, middle, oldest])
    }

    @Test
    func readOfMissingEnvelopeMintsNothing() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)

        #expect(try sync.mailActivities(at: key).isEmpty)
        #expect(try sidecars.allKeys().isEmpty)
    }

    @Test
    func sameMessageOnTwoCollapsedContactsMergesToOneCell() throws {
        // Case-D reconciliation merges a loser envelope into the winner cell by
        // cell. The Message-ID-derived key makes the same message one cell.
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let loserKey = SidecarKey(kind: .contact, id: "33333333-3333-3333-3333-333333333333")
        let message = try activity("<shared@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try sync.recordMailActivity(message, at: key)
        try sync.recordMailActivity(message, at: loserKey)

        let winner = try #require(try sidecars.read(key))
        let loser = try #require(try sidecars.read(loserKey))
        let rebased = SidecarEnvelope(entityID: winner.entityID, fields: loser.fields)
        let merged = try merge(winner, rebased).get()
        try sidecars.write(merged, at: key)

        #expect(merged.fields.keys.filter { $0.hasPrefix(MailActivity.cellKeyPrefix) }.count == 1)
        #expect(try sync.mailActivities(at: key) == [message])
    }

    // MARK: - Forward-compatible redelivery

    @Test
    func redeliveryKeepsInnerKeysANewerBuildAdded() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let received = Date(timeIntervalSince1970: 1_790_000_000)
        let original = try activity("<future@example.com>", receivedAt: received, subject: "First")
        try sync.recordMailActivity(original, at: key)

        // A newer build added a key inside the stored value object.
        let storedCell = try #require(try sidecars.read(key)?.fields[original.cellKey])
        guard case .object(var object) = storedCell.value else {
            Issue.record("stored activity is not an object")
            return
        }
        object["futureKey"] = .string("keep me")
        try seed([original.cellKey: foreignCell(.object(object))], in: sidecars)
        let seeded = try #require(try sidecars.read(key)?.fields[original.cellKey])

        // The same delivery again changes nothing, so nothing is written.
        let repeatOutcome = try sync.recordMailActivity(original, at: key)
        #expect(!repeatOutcome.didWrite)
        try expectSameCell(try sidecars.read(key)?.fields[original.cellKey], seeded)

        // A changed delivery writes this build's keys and keeps the new one.
        let updated = try activity("<future@example.com>", receivedAt: received, subject: "Second")
        let updateOutcome = try sync.recordMailActivity(updated, at: key)
        #expect(updateOutcome.activityChanged)
        let rewritten = try #require(try sidecars.read(key)?.fields[original.cellKey])
        guard case .object(let rewrittenObject) = rewritten.value else {
            Issue.record("rewritten activity is not an object")
            return
        }
        #expect(rewrittenObject["futureKey"] == .string("keep me"))
        #expect(rewrittenObject[MailActivity.subjectKey] == .string("Second"))
        #expect(rewritten.modifiedBy == "device-mail")
        #expect(try sync.mailActivities(at: key) == [updated])
    }

    @Test
    func redeliveryWithoutSubjectOrLinkKeepsTheStoredOnes() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let received = Date(timeIntervalSince1970: 1_790_000_000)
        let full = try activity(
            "<keep@example.com>", receivedAt: received, subject: "Hello", mailURL: "message://%3Ckeep@example.com%3E")
        let bare = try activity("<keep@example.com>", receivedAt: received, subject: nil, mailURL: nil)
        try sync.recordMailActivity(full, at: key)
        let before = try #require(try sidecars.read(key)?.fields[full.cellKey])

        let outcome = try sync.recordMailActivity(bare, at: key)

        #expect(!outcome.didWrite)
        try expectSameCell(try sidecars.read(key)?.fields[full.cellKey], before)
        #expect(try sync.mailActivities(at: key) == [full])
    }

    @Test
    func undecodableLiveCellIsNeverRewritten() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let message = try activity("<outgoing@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
        // A newer build stored this message with a direction this build does
        // not know.
        guard case .object(var object) = message.cellValue else {
            Issue.record("cell value is not an object")
            return
        }
        object[MailActivity.directionKey] = .string("outgoing")
        try seed([message.cellKey: foreignCell(.object(object))], in: sidecars)
        let seeded = try #require(try sidecars.read(key)?.fields[message.cellKey])

        let outcome = try sync.recordMailActivity(message, at: key)

        #expect(!outcome.activityChanged)
        try expectSameCell(try sidecars.read(key)?.fields[message.cellKey], seeded)
        #expect(try sync.mailActivities(at: key).isEmpty)
    }

    // MARK: - Retention

    @Test
    func retentionKeepsTheNewestHundredAndRemovesOlderCells() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let messages = try activities(MailActivity.retentionLimit + 1, from: start, prefix: "keep")

        // Exactly at the limit: nothing is removed.
        for message in messages.dropLast() {
            let outcome = try sync.recordMailActivity(message, at: key)
            #expect(outcome.prunedActivityCount == 0)
        }
        #expect(try sync.mailActivities(at: key).count == MailActivity.retentionLimit)

        // One past the limit removes the single oldest, physically.
        let newest = try #require(messages.last)
        let outcome = try sync.recordMailActivity(newest, at: key)
        #expect(outcome.activityChanged)
        #expect(outcome.prunedActivityCount == 1)

        let oldest = try #require(messages.first)
        let stored = try #require(try sidecars.read(key))
        #expect(stored.fields[oldest.cellKey] == nil)
        #expect(try sync.mailActivities(at: key) == Array(messages.dropFirst().reversed()))
    }

    @Test
    func activityOutsideTheWindowIsNotAdded() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for message in try activities(MailActivity.retentionLimit, from: start, prefix: "full") {
            try sync.recordMailActivity(message, at: key)
        }
        let before = try #require(try sidecars.read(key))

        let tooOld = try activity("<too-old@example.com>", receivedAt: start.addingTimeInterval(-60))
        let outcome = try sync.recordMailActivity(tooOld, at: key)

        #expect(outcome == MailActivityWriteOutcome(
            activityChanged: false,
            prunedActivityCount: 0,
            lastInteractedChanged: false,
            lastInteracted: start.addingTimeInterval(TimeInterval(MailActivity.retentionLimit - 1))
        ))
        let after = try #require(try sidecars.read(key))
        #expect(after.fields[tooOld.cellKey] == nil)
        #expect(Set(after.fields.keys) == Set(before.fields.keys))
    }

    @Test
    func retentionBreaksReceivedTimeTiesByID() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // 99 newer activities, then two sharing the oldest received time: only
        // one fits, and the one whose id sorts first ranks as newer.
        for message in try activities(MailActivity.retentionLimit - 1, from: start.addingTimeInterval(10), prefix: "new") {
            try sync.recordMailActivity(message, at: key)
        }
        let tiedA = try activity("<tie-a@example.com>", receivedAt: start)
        let tiedB = try activity("<tie-b@example.com>", receivedAt: start)
        let (kept, dropped) = tiedA.id.uuidString < tiedB.id.uuidString ? (tiedA, tiedB) : (tiedB, tiedA)

        try sync.recordMailActivity(dropped, at: key)
        let outcome = try sync.recordMailActivity(kept, at: key)

        #expect(outcome.activityChanged)
        #expect(outcome.prunedActivityCount == 1)
        let stored = try #require(try sidecars.read(key))
        #expect(stored.fields[kept.cellKey] != nil)
        #expect(stored.fields[dropped.cellKey] == nil)
    }

    @Test
    func retentionNeverRemovesOrCountsTombstonedOrUndecodableCells() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        // Older than everything else: a tombstone and a cell this build
        // cannot decode.
        let tombstoned = try activity("<deleted@example.com>", receivedAt: start.addingTimeInterval(-100))
        let unknown = try activity("<unknown@example.com>", receivedAt: start.addingTimeInterval(-100))
        guard case .object(var unknownObject) = unknown.cellValue else {
            Issue.record("cell value is not an object")
            return
        }
        unknownObject[MailActivity.directionKey] = .string("outgoing")
        try seed([
            tombstoned.cellKey: foreignCell(tombstoned.cellValue, deletedAt: start),
            unknown.cellKey: foreignCell(.object(unknownObject)),
        ], in: sidecars)

        // Merge-style over-limit envelope: 102 decodable live cells arrive
        // from another device without being pruned.
        let messages = try activities(MailActivity.retentionLimit + 2, from: start, prefix: "merged")
        try seed(
            Dictionary(uniqueKeysWithValues: messages.map { ($0.cellKey, foreignCell($0.cellValue)) }),
            in: sidecars
        )

        // A repeat of an already-stored message changes nothing itself, but the
        // write still trims the envelope back to the window.
        let outcome = try sync.recordMailActivity(try #require(messages.last), at: key)

        #expect(!outcome.activityChanged)
        #expect(outcome.prunedActivityCount == 2)
        let stored = try #require(try sidecars.read(key))
        #expect(stored.fields[messages[0].cellKey] == nil)
        #expect(stored.fields[messages[1].cellKey] == nil)
        #expect(stored.fields[tombstoned.cellKey]?.deletedAt == start)
        #expect(stored.fields[unknown.cellKey] != nil)
        #expect(try sync.mailActivities(at: key) == Array(messages.dropFirst(2).reversed()))
    }

    // MARK: - Cross-device convergence

    @Test
    func lastInteractedConvergesToTheLaterReceivedDateAcrossDevices() throws {
        // Two Macs record different messages for the same contact before
        // either sees the other's write. Mac B processes an OLDER message at
        // a LATER wall-clock time, so a write-time stamp would let it win.
        let storeA = InMemorySidecarStore()
        let storeB = InMemorySidecarStore()
        let macA = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: storeA, deviceID: "mac-A")
        let macB = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: storeB, deviceID: "mac-B")
        let earlier = try activity("<earlier@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let later = try activity("<later@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_003_600))

        try macA.recordMailActivity(later, at: key)
        try macB.recordMailActivity(earlier, at: key)
        let versionA = try SidecarEnvelopeCodec.encode(try #require(try storeA.read(key)))
        let versionB = try SidecarEnvelopeCodec.encode(try #require(try storeB.read(key)))

        // Each Mac resolves the iCloud conflict with the other's version.
        storeA.scriptConflict(at: key, versions: [versionB])
        storeB.scriptConflict(at: key, versions: [versionA])
        _ = try macA.reconcileSidecars()
        _ = try macB.reconcileSidecars()

        for (sync, store) in [(macA, storeA), (macB, storeB)] {
            #expect(try sync.contactTimestamps(at: key).lastInteracted == later.receivedAt)
            #expect(try sync.mailActivities(at: key) == [later, earlier])
            #expect(try SidecarEnvelopeCodec.encode(try #require(try store.read(key)))
                == SidecarEnvelopeCodec.encode(try #require(try storeA.read(key))))
        }
    }
}

/// The `ContactID`-keyed repository surface: writes resolve-or-mint, reads
/// never mint, the timestamp cache follows the stamp verbs, and a changed
/// activity posts the scoped `.contactsRepositoryMailActivityDidChange`.
@Suite("ContactsRepository mail activity")
@MainActor
struct ContactsRepositoryMailActivityTests {
    private func makeSync(_ store: InMemoryContactStore, _ sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
    }

    private func reconciled(_ localID: String, _ name: String, uuid: String) -> Contact {
        Contact(
            localID: localID,
            givenName: name,
            urlAddresses: [LabeledValue(label: "g", value: "\(SidecarKey.guessWhoContactURLPrefix)\(uuid)")]
        )
    }

    private func activity(_ messageID: String, receivedAt: Date) throws -> MailActivity {
        try #require(MailActivity(
            senderAddress: "ada@example.com",
            subject: "Hello",
            receivedAt: receivedAt,
            messageID: messageID
        ))
    }

    /// Polls until `condition` holds or `timeout` passes; returns whether it
    /// held. The sidecar refresh runs after the repository's 300 ms debounce.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test
    func queuedWritesThroughAPreMintTokenMintOnce() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "TARGET", givenName: "Ada")])
        let center = NotificationCenter()
        let repo = ContactsRepository(
            contacts: store,
            sync: makeSync(store, InMemorySidecarStore()),
            notificationCenter: center
        )

        // nonisolated(unsafe): appended only from the notification handlers
        // on this test's main-actor flow; read after the awaited writes.
        nonisolated(unsafe) var reloadFlags: [Bool] = []
        nonisolated(unsafe) var mailMintFlags: [Bool] = []
        nonisolated(unsafe) var mailProjectionFlags: [Bool] = []
        nonisolated(unsafe) var activityPosts: [[ContactID]] = []
        let reloadToken = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { note in
            reloadFlags.append(
                (note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true
            )
            mailMintFlags.append(
                (note.userInfo?[ContactsRepositoryDidReloadKey.mailActivityIdentityMinted] as? Bool) ?? false
            )
            mailProjectionFlags.append(
                (note.userInfo?[ContactsRepositoryDidReloadKey.mailContactProjectionChanged] as? Bool) ?? true
            )
        }
        let activityToken = center.addObserver(
            forName: .contactsRepositoryMailActivityDidChange, object: repo, queue: nil
        ) { note in
            activityPosts.append(
                (note.userInfo?[ContactsRepositoryMailActivityDidChangeKey.contactIDs] as? [ContactID]) ?? []
            )
        }
        defer {
            center.removeObserver(reloadToken)
            center.removeObserver(activityToken)
        }

        await repo.reload()
        let id = try #require(repo.contact(localID: "TARGET")).contactID
        #expect(id.guessWhoID == nil)

        // Two messages queued against the token captured before either write.
        try await repo.recordMailActivity(
            try activity("<queued-1@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            for: id
        )
        try await repo.recordMailActivity(
            try activity("<queued-2@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_060)),
            for: id
        )

        // One mint refresh (contactDataChanged: true). The second write found
        // the minted identity through the cache, so it posted only the
        // presentation-only reload for its newer lastInteracted.
        let minted = try #require(repo.contact(id: id)).contactID
        #expect(minted.guessWhoID != nil)
        #expect(reloadFlags == [true, true, false])
        #expect(mailMintFlags == [false, true, false])
        #expect(mailProjectionFlags == [true, false, false])
        #expect(activityPosts == [[minted, id], [minted, id]])
        #expect(await repo.mailActivities(for: id).map(\.messageID)
            == ["queued-2@example.com", "queued-1@example.com"])
    }

    @Test
    func remoteChangeWithExactContactKeyPostsScopedChange() async throws {
        let uuid = "90000000-0000-0000-0000-000000000001"
        let store = InMemoryContactStore(contacts: [reconciled("RECON", "Grace", uuid: uuid)])
        let sync = makeSync(store, InMemorySidecarStore())
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)

        // nonisolated(unsafe): appended only from the notification handlers
        // on this test's main-actor flow.
        nonisolated(unsafe) var reloadCount = 0
        nonisolated(unsafe) var activityPosts: [[ContactID]] = []
        let reloadToken = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { _ in reloadCount += 1 }
        let activityToken = center.addObserver(
            forName: .contactsRepositoryMailActivityDidChange, object: repo, queue: nil
        ) { note in
            activityPosts.append(
                (note.userInfo?[ContactsRepositoryMailActivityDidChangeKey.contactIDs] as? [ContactID]) ?? []
            )
        }
        defer {
            center.removeObserver(reloadToken)
            center.removeObserver(activityToken)
        }

        await repo.reload()
        let id = try #require(repo.contact(localID: "RECON")).contactID

        // Another device's write lands on disk; the watcher names its key.
        let key = SidecarKey(kind: .contact, id: uuid)
        try await sync.recordMailActivity(
            try activity("<remote@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            at: key
        )
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [key])]
        )
        #expect(await waitUntil { !activityPosts.isEmpty })
        #expect(activityPosts == [[id]])
        #expect(await repo.mailActivities(for: id).map(\.messageID) == ["remote@example.com"])

        // A coarse delivery names no contact: only the global reload posts.
        let reloadsBefore = reloadCount
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: nil, changedKinds: [.contact])]
        )
        #expect(await waitUntil { reloadCount > reloadsBefore })
        try await Task.sleep(for: .milliseconds(500))
        #expect(activityPosts == [[id]])
    }

    /// Collects every `.contactsRepositoryMailActivityDidChange` post from
    /// `repo`. `@unchecked Sendable`: the repository posts from the main
    /// actor, and the test reads `posts` on its main-actor flow.
    private final class MailActivityPostRecorder: @unchecked Sendable {
        var posts: [[ContactID]] = []
        private var token: NSObjectProtocol?
        private let center: NotificationCenter

        init(center: NotificationCenter, repo: ContactsRepository) {
            self.center = center
            token = center.addObserver(
                forName: .contactsRepositoryMailActivityDidChange, object: repo, queue: nil
            ) { [unowned self] note in
                self.posts.append(
                    (note.userInfo?[ContactsRepositoryMailActivityDidChangeKey.contactIDs] as? [ContactID]) ?? []
                )
            }
        }

        deinit {
            if let token { center.removeObserver(token) }
        }
    }

    private func postSidecarChange(_ keys: [SidecarKey], on center: NotificationCenter) {
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: Set(keys))]
        )
    }

    @Test
    func supersededExactKeyRefreshPostsNothingAndHandsItsKeysOn() async throws {
        let annaKey = SidecarKey(kind: .contact, id: "a1000000-0000-0000-0000-000000000001")
        let bobKey = SidecarKey(kind: .contact, id: "a1000000-0000-0000-0000-000000000002")
        let store = InMemoryContactStore(contacts: [
            reconciled("anna", "Anna", uuid: annaKey.id),
            reconciled("bob", "Bob", uuid: bobKey.id),
        ])
        let center = NotificationCenter()
        let repo = ContactsRepository(
            contacts: store,
            sync: makeSync(store, InMemorySidecarStore()),
            notificationCenter: center
        )
        await repo.reload()
        let annaID = try #require(repo.contact(localID: "anna")).contactID
        let bobID = try #require(repo.contact(localID: "bob")).contactID
        let recorder = MailActivityPostRecorder(center: center, repo: repo)

        // Park the refresh for Anna's key inside its scoped read.
        let gate = ContactsSidecarReadGate()
        repo.sidecarReadBarrierForTesting = { await gate.arriveAndWait() }
        postSidecarChange([annaKey], on: center)
        await gate.waitUntilReached()

        // A newer delivery for Bob supersedes it while it is parked.
        repo.sidecarReadBarrierForTesting = nil
        postSidecarChange([bobKey], on: center)
        #expect(await waitUntil { !recorder.posts.isEmpty })

        // Let the superseded refresh resume; it must stay silent.
        gate.release()
        try await Task.sleep(for: .milliseconds(100))

        // One post, from the successor, which inherited Anna's key.
        #expect(recorder.posts == [[annaID, bobID]])
    }

    @Test
    func exactContactKeyMissingFromTheCachePostsNothing() async throws {
        let knownKey = SidecarKey(kind: .contact, id: "a2000000-0000-0000-0000-000000000001")
        let unknownKey = SidecarKey(kind: .contact, id: "a2000000-0000-0000-0000-00000000ffff")
        let store = InMemoryContactStore(contacts: [reconciled("known", "Kim", uuid: knownKey.id)])
        let center = NotificationCenter()
        let repo = ContactsRepository(
            contacts: store,
            sync: makeSync(store, InMemorySidecarStore()),
            notificationCenter: center
        )
        await repo.reload()
        let knownID = try #require(repo.contact(localID: "known")).contactID
        let recorder = MailActivityPostRecorder(center: center, repo: repo)

        // nonisolated(unsafe): incremented only from the handler on this
        // test's main-actor flow.
        nonisolated(unsafe) var reloadCount = 0
        let reloadToken = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { _ in reloadCount += 1 }
        defer { center.removeObserver(reloadToken) }

        // Only a key the cache cannot resolve: the refresh still runs and
        // posts its reload, but names no contact.
        postSidecarChange([unknownKey], on: center)
        #expect(await waitUntil { reloadCount == 1 })
        #expect(recorder.posts.isEmpty)

        // Mixed: only the resolvable contact is listed.
        postSidecarChange([unknownKey, knownKey], on: center)
        #expect(await waitUntil { reloadCount == 2 })
        #expect(recorder.posts == [[knownID]])
    }

    @Test
    func groupEscalatedRefreshPostsForExactContactKeys() async throws {
        let contactKey = SidecarKey(kind: .contact, id: "a3000000-0000-0000-0000-000000000001")
        let groupKey = SidecarKey(kind: .group, id: "a3000000-0000-0000-0000-0000000000aa")
        let store = InMemoryContactStore(contacts: [reconciled("grace", "Grace", uuid: contactKey.id)])
        let sync = makeSync(store, InMemorySidecarStore())
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        let id = try #require(repo.contact(localID: "grace")).contactID
        let recorder = MailActivityPostRecorder(center: center, repo: repo)

        try await sync.recordMailActivity(
            try activity("<grouped@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            at: contactKey
        )
        // A `.group` key escalates to the full refresh; the exact contact key
        // alongside it still gets its scoped post.
        postSidecarChange([groupKey, contactKey], on: center)

        #expect(await waitUntil { !recorder.posts.isEmpty })
        #expect(recorder.posts == [[id]])
        #expect(await repo.mailActivities(for: id).map(\.messageID) == ["grouped@example.com"])
    }

    @Test
    func firstWriteToUnreconciledContactMintsAndRecords() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "TARGET", givenName: "Ada")])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(store, sidecars)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)

        // nonisolated(unsafe): appended only from the notification handler on
        // this test's main-actor flow; read after the awaited write.
        nonisolated(unsafe) var posted: [[ContactID]] = []
        let token = center.addObserver(
            forName: .contactsRepositoryMailActivityDidChange, object: repo, queue: nil
        ) { note in
            posted.append(
                (note.userInfo?[ContactsRepositoryMailActivityDidChangeKey.contactIDs] as? [ContactID]) ?? []
            )
        }
        defer { center.removeObserver(token) }

        await repo.reload()
        let id = try #require(repo.contact(localID: "TARGET")).contactID
        #expect(id.guessWhoID == nil)
        let message = try activity("<first@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))

        try await repo.recordMailActivity(message, for: id)

        // The write minted a GuessWho URL onto the record and keyed the data
        // on it.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        let guessWhoID = try #require(saved.contactID.guessWhoID)
        let refreshed = try #require(repo.contact(id: id)).contactID
        #expect(refreshed.guessWhoID == guessWhoID)
        #expect(refreshed != id)
        let stamps = try sync.contactTimestamps(at: SidecarKey(kind: .contact, id: guessWhoID))
        #expect(stamps.lastInteracted == message.receivedAt)
        #expect(stamps.lastViewed == nil)

        // The scoped post lists both tokens, and both read the activity back:
        // an open detail holding the pre-mint token needs no re-resolve.
        #expect(posted == [[refreshed, id]])
        #expect(await repo.mailActivities(for: refreshed) == [message])
        #expect(await repo.mailActivities(for: id) == [message])
    }

    @Test
    func readOnUnreconciledContactMintsNothing() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "TARGET", givenName: "Ada")])
        let sidecars = InMemorySidecarStore()
        let repo = ContactsRepository(contacts: store, sync: makeSync(store, sidecars))
        await repo.reload()

        let id = try #require(repo.contact(localID: "TARGET")).contactID
        #expect(await repo.mailActivities(for: id).isEmpty)

        let stored = try #require(try await store.fetch(localID: "TARGET"))
        #expect(stored.contactID.guessWhoID == nil)
        #expect(try sidecars.allKeys().isEmpty)
    }

    @Test
    func recordRefreshesLastInteractedCache() async throws {
        // Names put 'other' first alphabetically; the time sort must override
        // that with no reload between the write and the read.
        let store = InMemoryContactStore(contacts: [
            reconciled("mailed", "Zoe", uuid: "50000000-0000-0000-0000-000000000001"),
            reconciled("other", "Amy", uuid: "50000000-0000-0000-0000-000000000002"),
        ])
        let repo = ContactsRepository(contacts: store, sync: makeSync(store, InMemorySidecarStore()))
        await repo.reload()
        repo.sortOrder = .lastInteracted
        #expect(repo.people.map(\.localID) == ["other", "mailed"])

        let id = try #require(repo.contact(localID: "mailed")).contactID
        try await repo.recordMailActivity(
            try activity("<cache@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            for: id
        )

        #expect(repo.people.map(\.localID) == ["mailed", "other"])
    }

    @Test
    func postsOnlyWhenTheWriteChangedSomething() async throws {
        let store = InMemoryContactStore(contacts: [
            reconciled("RECON", "Grace", uuid: "60000000-0000-0000-0000-000000000001"),
        ])
        let center = NotificationCenter()
        let repo = ContactsRepository(
            contacts: store,
            sync: makeSync(store, InMemorySidecarStore()),
            notificationCenter: center
        )

        // nonisolated(unsafe): appended only from the notification handlers
        // on this test's main-actor flow; read after the awaited writes.
        nonisolated(unsafe) var reloadFlags: [Bool] = []
        nonisolated(unsafe) var activityPosts: [[ContactID]] = []
        let reloadToken = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { note in
            reloadFlags.append(
                (note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true
            )
        }
        let activityToken = center.addObserver(
            forName: .contactsRepositoryMailActivityDidChange, object: repo, queue: nil
        ) { note in
            activityPosts.append(
                (note.userInfo?[ContactsRepositoryMailActivityDidChangeKey.contactIDs] as? [ContactID]) ?? []
            )
        }
        defer {
            center.removeObserver(reloadToken)
            center.removeObserver(activityToken)
        }

        await repo.reload()
        let id = try #require(repo.contact(localID: "RECON")).contactID
        let message = try activity("<post@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))

        // New activity that also moves lastInteracted: the scoped post for the
        // detail, and a presentation-only reload for time-sorted lists.
        try await repo.recordMailActivity(message, for: id)
        #expect(reloadFlags == [true, false])
        #expect(activityPosts == [[id]])

        // Duplicate delivery: nothing written, nothing posted.
        try await repo.recordMailActivity(message, for: id)
        #expect(reloadFlags == [true, false])
        #expect(activityPosts == [[id]])

        // An older message records an activity but leaves lastInteracted, so
        // only the scoped post fires — no global reload.
        try await repo.recordMailActivity(
            try activity("<older@example.com>", receivedAt: Date(timeIntervalSince1970: 1_780_000_000)),
            for: id
        )
        #expect(reloadFlags == [true, false])
        #expect(activityPosts == [[id], [id]])
        #expect(await repo.mailActivities(for: id).map(\.messageID) == ["post@example.com", "older@example.com"])
    }

    @Test
    func mailActivityNeverAppearsAsACustomField() async throws {
        let uuid = "70000000-0000-0000-0000-000000000001"
        let store = InMemoryContactStore(contacts: [reconciled("RECON", "Grace", uuid: uuid)])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(store, sidecars)
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        let id = try #require(repo.contact(localID: "RECON")).contactID

        let fieldID = try await repo.upsertField(for: id, field: "Team", value: "Platform")
        try await repo.recordMailActivity(
            try activity("<field@example.com>", receivedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            for: id
        )

        // A mail activity cell whose payload is shaped exactly like a live
        // custom field, so only its key keeps it out of the field reads.
        let key = SidecarKey(kind: .contact, id: uuid)
        let envelope = try #require(try sidecars.read(key))
        var fields = envelope.fields
        fields[MailActivity.cellKeyPrefix + "80000000-0000-0000-0000-000000000001"] = SidecarCell(
            value: SidecarField.makeInnerValue(
                field: "Subject", type: .note, value: .string("Lunch?"), createdAt: Date()),
            modifiedAt: Date(),
            modifiedBy: "future-device"
        )
        try sidecars.write(SidecarEnvelope(entityID: envelope.entityID, fields: fields), at: key)

        // The engine funnel, the custom-field read, and the recovery read the
        // CLI/MCP field tools use all show only the real field.
        #expect(try sync.fields(at: key).map(\.id) == [fieldID])
        #expect(repo.fields(for: id).map(\.id) == [fieldID])
        #expect(repo.allFields(for: id).map(\.id) == [fieldID])
        #expect(await repo.mailActivities(for: id).map(\.messageID) == ["field@example.com"])
    }

    @Test
    func recordWithNilEngineThrows() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "T", givenName: "Z")])
        let repo = ContactsRepository(contacts: store)   // no sync engine
        await repo.reload()
        let id = try #require(repo.contact(localID: "T")).contactID
        let message = try activity("<none@example.com>", receivedAt: Date())

        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.recordMailActivity(message, for: id)
        }
        #expect(await repo.mailActivities(for: id).isEmpty)
    }
}
