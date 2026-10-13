import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Highlighted emails as stored cells on the contact envelope: the model's
/// Message-ID identity, the engine's upsert / tombstone / revive rules, and
/// the forward-compatibility contract (docs/sidecar-compatibility.md) — every
/// other cell survives each write.
@Suite("Highlighted email storage")
struct HighlightedEmailTests {
    private let key = SidecarKey(kind: .contact, id: "44444444-4444-4444-4444-444444444444")

    private func makeSync(_ sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-highlight"
        )
    }

    private func email(
        _ messageID: String,
        subject: String? = "Intro: Ada <> Grace",
        senderName: String? = "Ada Lovelace",
        senderAddress: String? = "ada@example.com",
        sentAt: Date? = Date(timeIntervalSince1970: 1_790_000_000),
        highlightedAt: Date = Date(timeIntervalSince1970: 1_791_000_000)
    ) throws -> HighlightedEmail {
        try #require(HighlightedEmail(
            messageID: messageID,
            subject: subject,
            senderName: senderName,
            senderAddress: senderAddress,
            sentAt: sentAt,
            highlightedAt: highlightedAt
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

    /// A cell holding `value`, stamped by another device.
    private func foreignCell(_ value: JSONValue, deletedAt: Date? = nil) -> SidecarCell {
        SidecarCell(
            value: value,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedBy: "other-device",
            deletedAt: deletedAt
        )
    }

    private func storedObject(_ email: HighlightedEmail, in sidecars: InMemorySidecarStore) throws -> [String: JSONValue] {
        let cell = try #require(try sidecars.read(key)?.fields[email.cellKey])
        guard case .object(let object) = cell.value else {
            Issue.record("stored highlighted email is not an object")
            return [:]
        }
        return object
    }

    @Test
    func starredActivitySavesMetadataAndCanBeUnstarredAndSavedAgain() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let activity = try #require(MailActivity(
            senderAddress: "ada@example.com",
            subject: "An important message",
            receivedAt: Date(timeIntervalSince1970: 1_790_000_000),
            messageID: "<star@Example.COM>"
        ))
        _ = try sync.recordMailActivity(activity, at: key)
        let before = try #require(try sidecars.read(key))
        let savedAt = Date(timeIntervalSince1970: 1_791_000_000)
        let saved = try #require(HighlightedEmail(activity: activity, highlightedAt: savedAt))
        #expect(saved.messageID == activity.messageID)
        #expect(saved.id != activity.id)
        #expect(saved.subject == activity.subject)
        #expect(saved.senderAddress == activity.senderAddress)
        #expect(saved.senderName == nil)
        #expect(saved.sentAt == activity.receivedAt)
        #expect(saved.highlightedAt == savedAt)

        #expect(try sync.highlightEmail(saved, at: key))
        #expect(try !sync.highlightEmail(saved, at: key))
        let activities = try sync.mailActivities(at: key)
        let highlighted = try sync.highlightedEmails(at: key)
        #expect(highlighted == [saved])
        #expect(activities == [activity])
        #expect(MailActivity.excludingHighlightedEmails(highlighted, from: activities).isEmpty)
        let after = try sidecars.read(key)
        // Saving does not modify activity history or lastInteracted.
        for (key, cell) in before.fields {
            try expectSameCell(cell, after?.fields[key])
        }

        #expect(try sync.removeHighlightedEmail(id: saved.id, at: key))
        let removed = try sync.highlightedEmails(at: key)
        let remainingActivities = try sync.mailActivities(at: key)
        #expect(removed.isEmpty)
        #expect(remainingActivities == [activity])
        #expect(MailActivity.excludingHighlightedEmails(removed, from: remainingActivities) == [activity])
        #expect(try sync.highlightEmail(saved, at: key))
        #expect(try sync.highlightedEmails(at: key) == [saved])
    }

    @Test
    func recentEmailsExcludeAllSavedMessagesBeforeTakingTen() throws {
        let activities = try (0..<15).map { index in
            try #require(MailActivity(
                senderAddress: "ada@example.com",
                subject: "Same subject",
                receivedAt: Date(timeIntervalSince1970: Double(1_790_000_000 - index)),
                messageID: "<message\(index)@EXAMPLE.com>"
            ))
        }
        // Dropped messages match too, independent of subject or sender.
        let saved = try [
            email("message0@example.com", subject: "A different subject"),
            email("<message1@Example.com>"),
            email("<message12@example.com>"),
            email("<unrelated@example.com>"),
        ]
        let filtered = MailActivity.excludingHighlightedEmails(saved, from: activities)
        #expect(filtered == Array(activities[2..<12]) + Array(activities[13..<15]))
        #expect(Array(filtered.prefix(10)) == Array(activities[2..<12]))
        #expect(MailActivity.excludingHighlightedEmails([], from: activities) == activities)
        #expect(MailActivity.excludingHighlightedEmails(saved, from: []).isEmpty)
        // Message-ID local parts are case-sensitive.
        let differentCase = try email("<MESSAGE0@example.com>")
        #expect(MailActivity.excludingHighlightedEmails([differentCase], from: activities) == activities)
    }

    // MARK: - Model

    @Test
    func messageIDSpellingsShareOneIdentity() throws {
        let bracketed = try email("<abc.123@Example.COM>")
        let bare = try email("  abc.123@example.com ")
        let folded = try email("<abc.123@\r\n example.com>")

        #expect(bracketed.messageID == "abc.123@example.com")
        #expect(bracketed.id == bare.id)
        #expect(bracketed.id == folded.id)
        #expect(HighlightedEmail.emailID(forMessageID: "<abc.123@example.com>") == bracketed.id)
        // The id is part of the synced format: SHA-256 over
        // "highlighted-email\n" + the normalized Message-ID.
        #expect(bracketed.id == UUID(uuidString: "B34A97C2-170E-5A06-AD90-4445FD43E838"))
        #expect(bracketed.cellKey == "highlightedEmail:b34a97c2-170e-5a06-ad90-4445fd43e838")

        // Its own namespace: the same message as a mail activity is a
        // different id.
        #expect(bracketed.id != MailActivity.activityID(forMessageID: "<abc.123@example.com>"))
        // The local part keeps its case.
        #expect(try email("<ABC.123@example.com>").id != bracketed.id)
    }

    @Test
    func emptyMessageIDHasNoIdentity() {
        for raw in ["", "   ", "<>", "< \r\n >"] {
            #expect(HighlightedEmail.emailID(forMessageID: raw) == nil)
            #expect(HighlightedEmail(
                messageID: raw,
                subject: "Hi",
                senderName: nil,
                senderAddress: nil,
                sentAt: nil,
                highlightedAt: Date()
            ) == nil)
        }
    }

    @Test
    func initTrimsStringsAndRoundsDates() throws {
        let sentAt = Date(timeIntervalSince1970: 1_790_000_000.123456)
        let highlightedAt = Date(timeIntervalSince1970: 1_791_000_000.987654)
        let trimmed = try email(
            "<trim@example.com>",
            subject: "  Hello \n",
            senderName: " Ada ",
            senderAddress: "\tada@example.com ",
            sentAt: sentAt,
            highlightedAt: highlightedAt
        )
        #expect(trimmed.subject == "Hello")
        #expect(trimmed.senderName == "Ada")
        #expect(trimmed.senderAddress == "ada@example.com")
        // Both dates are at the stored (millisecond) precision, so a value
        // read back compares equal to the one written.
        #expect(trimmed.sentAt != sentAt)
        #expect(trimmed.sentAt == SidecarISO8601.date(from: SidecarISO8601.string(from: sentAt)))
        #expect(trimmed.highlightedAt != highlightedAt)
        #expect(trimmed.highlightedAt == SidecarISO8601.date(from: SidecarISO8601.string(from: highlightedAt)))

        let empty = try email("<empty@example.com>", subject: "  ", senderName: "", senderAddress: " \n ")
        #expect(empty.subject == nil)
        #expect(empty.senderName == nil)
        #expect(empty.senderAddress == nil)
    }

    @Test
    func headersMapOntoAHighlightedEmail() throws {
        let sentAt = Date(timeIntervalSince1970: 1_790_000_000.123456)
        let highlightedAt = Date(timeIntervalSince1970: 1_791_000_000.987654)
        let headers = EmailMessageHeaders(
            messageID: "<abc.123@Example.COM>",
            subject: " Intro ",
            fromName: "Ada Lovelace",
            fromAddress: "ada@example.com",
            date: sentAt
        )

        let mapped = try #require(HighlightedEmail(headers: headers, highlightedAt: highlightedAt))
        // Identical to the field-by-field init: same normalization, trimming,
        // and stored precision.
        let direct = try email(
            "<abc.123@Example.COM>",
            subject: " Intro ",
            senderName: "Ada Lovelace",
            senderAddress: "ada@example.com",
            sentAt: sentAt,
            highlightedAt: highlightedAt
        )
        #expect(mapped == direct)
        #expect(mapped.messageID == "abc.123@example.com")
        #expect(mapped.subject == "Intro")
        #expect(mapped.senderName == "Ada Lovelace")
        #expect(mapped.senderAddress == "ada@example.com")
        #expect(mapped.sentAt == SidecarISO8601.date(from: SidecarISO8601.string(from: sentAt)))

        // Only the Message-ID is required.
        let bare = try #require(HighlightedEmail(
            headers: EmailMessageHeaders(messageID: "<bare@example.com>"),
            highlightedAt: highlightedAt
        ))
        #expect(bare.subject == nil)
        #expect(bare.senderName == nil)
        #expect(bare.senderAddress == nil)
        #expect(bare.sentAt == nil)
        #expect(bare.sortDate == bare.highlightedAt)
    }

    @Test
    func headersWithoutAUsableMessageIDMapToNil() {
        let noID = EmailMessageHeaders(subject: "Hi", fromAddress: "ada@example.com")
        #expect(HighlightedEmail(headers: noID, highlightedAt: Date()) == nil)
        let emptyID = EmailMessageHeaders(messageID: "<>", subject: "Hi")
        #expect(HighlightedEmail(headers: emptyID, highlightedAt: Date()) == nil)
    }

    @Test
    func orderIsNewerSortDateFirstWithIDTieBreak() throws {
        let undated = try email(
            "<undated@example.com>", sentAt: nil, highlightedAt: Date(timeIntervalSince1970: 1_795_000_000))
        #expect(undated.sortDate == undated.highlightedAt)
        let sent = try email("<sent@example.com>", sentAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(sent.sortDate == sent.sentAt)
        #expect(undated.isNewer(than: sent))
        #expect(!sent.isNewer(than: undated))

        let tiedA = try email("<tie-a@example.com>")
        let tiedB = try email("<tie-b@example.com>")
        let first = tiedA.id.uuidString < tiedB.id.uuidString ? tiedA : tiedB
        let second = first == tiedA ? tiedB : tiedA
        #expect(first.isNewer(than: second))
        #expect(!second.isNewer(than: first))
    }

    // MARK: - Engine

    @Test
    func writeThenReadRoundTrips() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let full = try email("<full@example.com>", sentAt: Date(timeIntervalSince1970: 1_790_000_000.5))
        let bare = try email(
            "<bare@example.com>",
            subject: nil,
            senderName: nil,
            senderAddress: nil,
            sentAt: nil,
            highlightedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        #expect(try sync.highlightEmail(full, at: key))
        #expect(try sync.highlightEmail(bare, at: key))
        #expect(try sync.highlightedEmails(at: key) == [full, bare])

        // Optional members are omitted when nil, and the field spellings are
        // the synced format.
        #expect(Set(try storedObject(bare, in: sidecars).keys) == ["messageID", "highlightedAt"])
        #expect(Set(try storedObject(full, in: sidecars).keys)
            == ["messageID", "highlightedAt", "subject", "senderName", "sender", "sentAt"])

        // Serialization leg: the envelope survives the production codec and
        // decodes back to the same emails.
        let envelope = try #require(try sidecars.read(key))
        let data = try SidecarEnvelopeCodec.encode(envelope)
        let decoded = try JSONDecoder().decode(SidecarEnvelope.self, from: data)
        #expect(decoded.cellsDroppedOnDecode == 0)
        for written in [full, bare] {
            let cell = try #require(decoded.fields[written.cellKey])
            #expect(HighlightedEmail(cellKey: written.cellKey, cell: cell) == written)
        }
    }

    @Test
    func repeatDropIsANoOpWrite() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let dropped = try email("<dup@example.com>")
        #expect(try sync.highlightEmail(dropped, at: key))
        let before = try #require(try sidecars.read(key)?.fields[dropped.cellKey])

        // Same message, other spelling, dropped later: nothing to write.
        let again = try email("dup@EXAMPLE.com", highlightedAt: Date(timeIntervalSince1970: 1_799_000_000))
        #expect(try sync.highlightEmail(again, at: key) == false)

        try expectSameCell(try sidecars.read(key)?.fields[dropped.cellKey], before)
        #expect(try sync.highlightedEmails(at: key) == [dropped])
    }

    @Test
    func overlayKeepsStoredHighlightedAtAndFillsAMissingOptional() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let firstDrop = Date(timeIntervalSince1970: 1_791_000_000)
        let original = try email("<fill@example.com>", subject: nil, sentAt: nil, highlightedAt: firstDrop)
        try sync.highlightEmail(original, at: key)

        let later = try email(
            "<fill@example.com>",
            subject: "Now with a subject",
            sentAt: Date(timeIntervalSince1970: 1_790_000_000),
            highlightedAt: Date(timeIntervalSince1970: 1_799_000_000)
        )
        #expect(try sync.highlightEmail(later, at: key))

        let stored = try #require(try sync.highlightedEmails(at: key).first)
        #expect(stored.subject == "Now with a subject")
        #expect(stored.sentAt == later.sentAt)
        #expect(stored.highlightedAt == firstDrop)
        let cell = try #require(try sidecars.read(key)?.fields[original.cellKey])
        #expect(cell.modifiedBy == "device-highlight")
        #expect(cell.deletedAt == nil)
    }

    @Test
    func overlayKeepsStoredOptionalsAndKeysANewerBuildAdded() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let full = try email("<future@example.com>")
        try sync.highlightEmail(full, at: key)

        // A newer build added a key inside the stored value object.
        var object = try storedObject(full, in: sidecars)
        object["futureKey"] = .string("keep me")
        try seed([full.cellKey: foreignCell(.object(object))], in: sidecars)
        let seeded = try #require(try sidecars.read(key)?.fields[full.cellKey])

        // A drop carrying none of the optionals changes nothing.
        let bare = try email(
            "<future@example.com>", subject: nil, senderName: nil, senderAddress: nil, sentAt: nil)
        #expect(try sync.highlightEmail(bare, at: key) == false)
        try expectSameCell(try sidecars.read(key)?.fields[full.cellKey], seeded)

        // A changed drop writes this build's keys and keeps the new one.
        let renamed = try email("<future@example.com>", senderName: "Ada King")
        #expect(try sync.highlightEmail(renamed, at: key))
        let rewritten = try storedObject(full, in: sidecars)
        #expect(rewritten["futureKey"] == .string("keep me"))
        #expect(rewritten[HighlightedEmail.senderNameKey] == .string("Ada King"))
        #expect(try sync.highlightedEmails(at: key) == [renamed])
    }

    @Test
    func removeTombstonesAndHidesTheEmail() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let kept = try email("<kept@example.com>")
        let removed = try email("<removed@example.com>")
        try sync.highlightEmail(kept, at: key)
        try sync.highlightEmail(removed, at: key)
        let live = try #require(try sidecars.read(key)?.fields[removed.cellKey])

        #expect(try sync.removeHighlightedEmail(id: removed.id, at: key))

        // The cell stays, with its value, stamped as deleted by this device.
        let tombstone = try #require(try sidecars.read(key)?.fields[removed.cellKey])
        #expect(tombstone.value == live.value)
        let deletedAt = try #require(tombstone.deletedAt)
        #expect(tombstone.modifiedAt == deletedAt)
        #expect(tombstone.modifiedBy == "device-highlight")
        #expect(try sync.highlightedEmails(at: key) == [kept])

        // Removing again, or removing an email never stored, writes nothing.
        #expect(try sync.removeHighlightedEmail(id: removed.id, at: key) == false)
        try expectSameCell(try sidecars.read(key)?.fields[removed.cellKey], tombstone)
        let unknown = try #require(HighlightedEmail.emailID(forMessageID: "<never@example.com>"))
        #expect(try sync.removeHighlightedEmail(id: unknown, at: key) == false)
    }

    @Test
    func reDropAfterRemoveRevivesWithTheNewValue() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let original = try email("<revive@example.com>", subject: "First")
        try sync.highlightEmail(original, at: key)
        try sync.removeHighlightedEmail(id: original.id, at: key)
        #expect(try sync.highlightedEmails(at: key).isEmpty)

        let again = try email(
            "<revive@example.com>",
            subject: nil,
            highlightedAt: Date(timeIntervalSince1970: 1_799_000_000)
        )
        #expect(try sync.highlightEmail(again, at: key))

        // A fresh live cell holding this drop's full value: the new
        // highlightedAt, and no subject carried over from the removed one.
        let cell = try #require(try sidecars.read(key)?.fields[original.cellKey])
        #expect(cell.deletedAt == nil)
        #expect(cell.value == again.cellValue)
        #expect(try sync.highlightedEmails(at: key) == [again])
    }

    @Test
    func undecodableLiveCellIsNeverRewritten() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let dropped = try email("<broken@example.com>")
        // A live cell at this email's key with no valid highlightedAt.
        guard case .object(var object) = dropped.cellValue else {
            Issue.record("cell value is not an object")
            return
        }
        object[HighlightedEmail.highlightedAtKey] = .string("not a date")
        try seed([dropped.cellKey: foreignCell(.object(object))], in: sidecars)
        let seeded = try #require(try sidecars.read(key)?.fields[dropped.cellKey])

        #expect(try sync.highlightEmail(dropped, at: key) == false)
        try expectSameCell(try sidecars.read(key)?.fields[dropped.cellKey], seeded)
        #expect(try sync.highlightedEmails(at: key).isEmpty)
    }

    @Test
    func lastInteractedIsNeverTouched() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)

        // No lastInteracted yet: a drop does not create one.
        try sync.highlightEmail(try email("<first@example.com>"), at: key)
        #expect(try sync.contactTimestamps(at: key).lastInteracted == nil)
        #expect(try sidecars.read(key)?.fields[ContactTimestamps.lastInteractedKey] == nil)

        // An existing lastInteracted older than the message stays put.
        let interacted = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(.interacted, at: key, now: interacted)
        let stamp = try #require(try sidecars.read(key)?.fields[ContactTimestamps.lastInteractedKey])
        let newer = try email("<newer@example.com>", sentAt: Date(timeIntervalSince1970: 1_795_000_000))
        try sync.highlightEmail(newer, at: key)
        try sync.removeHighlightedEmail(id: newer.id, at: key)
        try sync.highlightEmail(newer, at: key)

        try expectSameCell(try sidecars.read(key)?.fields[ContactTimestamps.lastInteractedKey], stamp)
        #expect(try sync.contactTimestamps(at: key).lastInteracted == interacted)
    }

    @Test
    func noRetentionLimitKeepsEveryEmail() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let emails = try (0..<150).map { index in
            try email("<kept-\(index)@example.com>", sentAt: start.addingTimeInterval(TimeInterval(index)))
        }
        for dropped in emails {
            #expect(try sync.highlightEmail(dropped, at: key))
        }

        #expect(try sync.highlightedEmails(at: key) == Array(emails.reversed()))
        let stored = try #require(try sidecars.read(key))
        #expect(stored.fields.keys.filter(HighlightedEmail.isCellKey).count == 150)
    }

    @Test
    func fieldsNeverReturnsHighlightedEmailCells() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let fieldID = try sync.addField(at: key, field: "Team", type: .note, value: .string("Platform"))
        let live = try email("<live@example.com>")
        let removed = try email("<removed@example.com>")
        try sync.highlightEmail(live, at: key)
        try sync.highlightEmail(removed, at: key)
        try sync.removeHighlightedEmail(id: removed.id, at: key)

        // Cells shaped exactly like a live and a deleted custom field, so only
        // the key keeps them out of the field reads.
        let shapedLikeAField = SidecarField.makeInnerValue(
            field: "Subject", type: .note, value: .string("Lunch?"), createdAt: Date())
        try seed([
            HighlightedEmail.cellKeyPrefix + "80000000-0000-0000-0000-000000000001":
                foreignCell(shapedLikeAField),
            HighlightedEmail.cellKeyPrefix + "80000000-0000-0000-0000-000000000002":
                foreignCell(shapedLikeAField, deletedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ], in: sidecars)

        #expect(try sync.fields(at: key).map(\.id) == [fieldID])
        #expect(try sync.notes(at: key).isEmpty)
        #expect(try sync.allNotes(at: key).isEmpty)
        #expect(try sync.highlightedEmails(at: key) == [live])
    }

    @Test
    func everyWritePreservesEveryOtherCell() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        // A note, a stamp, a mail activity, and two cells from a newer build.
        _ = try sync.addNote(at: key, body: "met at WWDC")
        try sync.stampContactTimestamp(.viewed, at: key, now: stamp)
        let activity = try #require(MailActivity(
            senderAddress: "ada@example.com",
            subject: "Lunch?",
            receivedAt: Date(timeIntervalSince1970: 1_790_000_000),
            messageID: "<activity@example.com>"
        ))
        try sync.recordMailActivity(activity, at: key)
        try seed([
            "abababab-abab-abab-abab-abababababab": foreignCell(.object([
                SidecarField.innerFieldKey: .string("source"),
                SidecarField.innerTypeKey: .string("type_from_the_future"),
                SidecarField.innerValueKey: .string("x"),
            ])),
            "futureCell": foreignCell(.object(["futureKey": .string("keep me")])),
        ], in: sidecars)
        let before = try #require(try sidecars.read(key))

        let dropped = try email("<keep@example.com>", subject: nil)
        try sync.highlightEmail(dropped, at: key)
        try sync.highlightEmail(try email("<keep@example.com>", subject: "Overlay"), at: key)
        try sync.removeHighlightedEmail(id: dropped.id, at: key)
        try sync.highlightEmail(dropped, at: key)

        // Every pre-existing cell is untouched; the one highlighted-email cell
        // is the only addition.
        let after = try #require(try sidecars.read(key))
        #expect(after.entityID == before.entityID)
        for (cellKey, cell) in before.fields {
            try expectSameCell(after.fields[cellKey], cell)
        }
        #expect(Set(after.fields.keys).subtracting(before.fields.keys) == [dropped.cellKey])
        #expect(try sync.mailActivities(at: key) == [activity])

        // And an ordinary field write (the raw read-modify-write an older
        // build also does) carries the highlighted-email cell through.
        let emailCell = after.fields[dropped.cellKey]
        try sync.addField(at: key, field: "nickname", type: .note, value: .string("Ada"))
        try expectSameCell(try sidecars.read(key)?.fields[dropped.cellKey], emailCell)
    }

    @Test
    func firstDropMintsTheEnvelopeAndReadOfMissingEnvelopeMintsNothing() throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)

        #expect(try sync.highlightedEmails(at: key).isEmpty)
        #expect(try sync.removeHighlightedEmail(id: UUID(), at: key) == false)
        #expect(try sidecars.allKeys().isEmpty)

        try sync.highlightEmail(try email("<mint@example.com>"), at: key)
        #expect(try sidecars.read(key)?.entityID == key.id)
    }

    @Test
    func tombstoneWinsAMergeWithAnOlderLiveCopy() throws {
        // The reason remove never deletes the cell: the merge is a union, and
        // a peer still holding the live cell must not bring it back.
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let dropped = try email("<merge@example.com>")
        try sync.highlightEmail(dropped, at: key)
        let peer = try #require(try sidecars.read(key))
        try sync.removeHighlightedEmail(id: dropped.id, at: key)
        let local = try #require(try sidecars.read(key))

        let merged = try merge(local, peer).get()
        try sidecars.write(merged, at: key)

        #expect(merged.fields[dropped.cellKey]?.deletedAt != nil)
        #expect(try sync.highlightedEmails(at: key).isEmpty)
    }

    @Test
    func asyncOverloadsMatchTheSyncVerbs() async throws {
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(sidecars)
        let dropped = try email("<async@example.com>")

        #expect(try await sync.highlightEmail(dropped, at: key))
        #expect(try await sync.highlightedEmails(at: key) == [dropped])
        #expect(try await sync.removeHighlightedEmail(id: dropped.id, at: key))
        #expect(try await sync.highlightedEmails(at: key).isEmpty)
    }
}

/// The `ContactID`-keyed repository surface: writes resolve-or-mint, reads
/// and removes never mint, and a changed write posts the scoped
/// `.contactsRepositoryHighlightedEmailsDidChange`.
@Suite("ContactsRepository highlighted email")
@MainActor
struct ContactsRepositoryHighlightedEmailTests {
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

    private func email(_ messageID: String, subject: String? = "Hello") throws -> HighlightedEmail {
        try #require(HighlightedEmail(
            messageID: messageID,
            subject: subject,
            senderName: "Someone Related",
            senderAddress: "related@example.com",
            sentAt: Date(timeIntervalSince1970: 1_790_000_000),
            highlightedAt: Date(timeIntervalSince1970: 1_791_000_000)
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

    /// Collects every highlighted-email change post and every reload's
    /// `contactDataChanged` flag from `repo`. `@unchecked Sendable`: the
    /// repository posts from the main actor, and the test reads on its
    /// main-actor flow.
    private final class PostRecorder: @unchecked Sendable {
        var posts: [[ContactID]] = []
        var reloadFlags: [Bool] = []
        private var tokens: [NSObjectProtocol] = []
        private let center: NotificationCenter

        init(center: NotificationCenter, repo: ContactsRepository) {
            self.center = center
            tokens.append(center.addObserver(
                forName: .contactsRepositoryHighlightedEmailsDidChange, object: repo, queue: nil
            ) { [unowned self] note in
                self.posts.append(
                    (note.userInfo?[ContactsRepositoryHighlightedEmailsDidChangeKey.contactIDs] as? [ContactID]) ?? []
                )
            })
            tokens.append(center.addObserver(
                forName: .contactsRepositoryDidReload, object: repo, queue: nil
            ) { [unowned self] note in
                self.reloadFlags.append(
                    (note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true
                )
            })
        }

        deinit {
            for token in tokens { center.removeObserver(token) }
        }
    }

    @Test
    func postsOnlyWhenTheWriteChangedSomething() async throws {
        let store = InMemoryContactStore(contacts: [
            reconciled("RECON", "Grace", uuid: "61000000-0000-0000-0000-000000000001"),
        ])
        let center = NotificationCenter()
        let repo = ContactsRepository(
            contacts: store,
            sync: makeSync(store, InMemorySidecarStore()),
            notificationCenter: center
        )
        await repo.reload()
        let id = try #require(repo.contact(localID: "RECON")).contactID
        let recorder = PostRecorder(center: center, repo: repo)
        let dropped = try email("<post@example.com>")

        try await repo.highlightEmail(dropped, for: id)
        #expect(recorder.posts == [[id]])

        // Repeat drop: nothing written, nothing posted.
        try await repo.highlightEmail(dropped, for: id)
        #expect(recorder.posts == [[id]])

        try await repo.removeHighlightedEmail(id: dropped.id, for: id)
        #expect(recorder.posts == [[id], [id]])

        // Already removed: nothing posted.
        try await repo.removeHighlightedEmail(id: dropped.id, for: id)
        #expect(recorder.posts == [[id], [id]])

        // No write moved a cached record or a timestamp, so no global reload.
        #expect(recorder.reloadFlags.isEmpty)
        #expect(await repo.highlightedEmails(for: id).isEmpty)
    }

    @Test
    func firstDropOnUnreconciledContactMintsOnce() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "TARGET", givenName: "Ada")])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(store, sidecars)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        let id = try #require(repo.contact(localID: "TARGET")).contactID
        #expect(id.guessWhoID == nil)
        let recorder = PostRecorder(center: center, repo: repo)
        let first = try email("<first@example.com>")

        try await repo.highlightEmail(first, for: id)

        // The write minted a GuessWho URL onto the record and keyed the data
        // on it; the cache refresh posted one data-changed reload.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        let guessWhoID = try #require(saved.contactID.guessWhoID)
        let refreshed = try #require(repo.contact(id: id)).contactID
        #expect(refreshed.guessWhoID == guessWhoID)
        #expect(recorder.reloadFlags == [true])
        #expect(recorder.posts == [[refreshed, id]])
        #expect(try sync.contactTimestamps(at: SidecarKey(kind: .contact, id: guessWhoID)).lastInteracted == nil)

        // A second drop through the pre-mint token resolves through the cache:
        // no second reconcile, no second reload, same identity.
        let second = try email("<second@example.com>")
        try await repo.highlightEmail(second, for: id)
        #expect(recorder.reloadFlags == [true])
        #expect(recorder.posts == [[refreshed, id], [refreshed, id]])
        #expect(try await store.fetch(localID: "TARGET")?.contactID.guessWhoID == guessWhoID)

        // Both tokens read the emails back.
        let viaRefreshed = await repo.highlightedEmails(for: refreshed)
        let viaPreMint = await repo.highlightedEmails(for: id)
        #expect(viaRefreshed == [first, second].sorted { $0.isNewer(than: $1) })
        #expect(viaPreMint == viaRefreshed)

        // Removing through the pre-mint token reaches the minted identity too.
        try await repo.removeHighlightedEmail(id: first.id, for: id)
        #expect(recorder.posts.last == [refreshed, id])
        #expect(await repo.highlightedEmails(for: refreshed) == [second])
    }

    @Test
    func readAndRemoveOnUnreconciledContactMintNothing() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "TARGET", givenName: "Ada")])
        let sidecars = InMemorySidecarStore()
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: makeSync(store, sidecars), notificationCenter: center)
        await repo.reload()
        let id = try #require(repo.contact(localID: "TARGET")).contactID
        let recorder = PostRecorder(center: center, repo: repo)

        #expect(await repo.highlightedEmails(for: id).isEmpty)
        let never = try email("<none@example.com>")
        try await repo.removeHighlightedEmail(id: never.id, for: id)

        let stored = try #require(try await store.fetch(localID: "TARGET"))
        #expect(stored.contactID.guessWhoID == nil)
        #expect(try sidecars.allKeys().isEmpty)
        #expect(recorder.posts.isEmpty)
        #expect(recorder.reloadFlags.isEmpty)
    }

    @Test
    func remoteChangeWithExactContactKeyPostsScopedChange() async throws {
        let uuid = "91000000-0000-0000-0000-000000000001"
        let store = InMemoryContactStore(contacts: [reconciled("RECON", "Grace", uuid: uuid)])
        let sync = makeSync(store, InMemorySidecarStore())
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        let id = try #require(repo.contact(localID: "RECON")).contactID
        let recorder = PostRecorder(center: center, repo: repo)

        // Another device's write lands on disk; the watcher names its key.
        let key = SidecarKey(kind: .contact, id: uuid)
        try await sync.highlightEmail(try email("<remote@example.com>"), at: key)
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [key])]
        )
        #expect(await waitUntil { !recorder.posts.isEmpty })
        #expect(recorder.posts == [[id]])
        #expect(await repo.highlightedEmails(for: id).map(\.messageID) == ["remote@example.com"])

        // A coarse delivery names no contact: only the global reload posts.
        let reloadsBefore = recorder.reloadFlags.count
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: nil, changedKinds: [.contact])]
        )
        #expect(await waitUntil { recorder.reloadFlags.count > reloadsBefore })
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.posts == [[id]])
    }

    @Test
    func highlightedEmailsNeverAppearAsCustomFields() async throws {
        let uuid = "71000000-0000-0000-0000-000000000001"
        let store = InMemoryContactStore(contacts: [reconciled("RECON", "Grace", uuid: uuid)])
        let repo = ContactsRepository(contacts: store, sync: makeSync(store, InMemorySidecarStore()))
        await repo.reload()
        let id = try #require(repo.contact(localID: "RECON")).contactID

        let fieldID = try await repo.upsertField(for: id, field: "Team", value: "Platform")
        let live = try email("<live@example.com>")
        let removed = try email("<removed@example.com>")
        try await repo.highlightEmail(live, for: id)
        try await repo.highlightEmail(removed, for: id)
        try await repo.removeHighlightedEmail(id: removed.id, for: id)

        // The custom-field read and the recovery read the CLI/MCP field tools
        // and Recently Deleted use both show only the real field.
        #expect(repo.fields(for: id).map(\.id) == [fieldID])
        #expect(repo.allFields(for: id).map(\.id) == [fieldID])
        #expect(await repo.highlightedEmails(for: id) == [live])
    }

    @Test
    func writesWithNilEngineThrow() async throws {
        let store = InMemoryContactStore(contacts: [Contact(localID: "T", givenName: "Z")])
        let repo = ContactsRepository(contacts: store)   // no sync engine
        await repo.reload()
        let id = try #require(repo.contact(localID: "T")).contactID
        let dropped = try email("<none@example.com>")

        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.highlightEmail(dropped, for: id)
        }
        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.removeHighlightedEmail(id: dropped.id, for: id)
        }
        #expect(await repo.highlightedEmails(for: id).isEmpty)
    }
}
