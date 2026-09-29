import Foundation
import Testing
@testable import GuessWho

/// The Foundation-only file format the app shares with the Apple Mail
/// extension (App/GuessWhoMailShared): address normalization, the contact
/// snapshot and its store, Message-ID handling, and the incoming-message
/// journal's claim/acknowledge transaction. Every test works in its own
/// temporary directory, never the real App Group container.

@Suite("Mail handoff: address normalization")
struct MailAddressNormalizerTests {

    @Test(arguments: [
        ("Jane.Doe@Example.COM", "jane.doe@example.com"),
        ("  jane@example.com \n", "jane@example.com"),
        ("Jane Doe <Jane@Example.com>", "jane@example.com"),
        ("\"Doe, Jane <work>\" <jane@example.com>", "jane@example.com"),
        ("mailto:Jane@Example.com?subject=Hi", "jane@example.com"),
        ("MAILTO:jane%2Bnews@example.com", "jane+news@example.com"),
        ("jane@example.com.", "jane@example.com"),
    ])
    func normalizes(_ testCase: (raw: String, expected: String)) {
        #expect(MailAddressNormalizer.normalize(testCase.raw) == testCase.expected)
    }

    @Test(arguments: [
        "", "   ", "jane", "@example.com", "jane@", "jane@@example.com", "a@b@example.com",
        "jane doe@example.com", "Jane <jane@example.com", "jane@example.com>",
        String(repeating: "a", count: 310) + "@example.com",
    ])
    func rejects(_ raw: String) {
        #expect(MailAddressNormalizer.normalize(raw) == nil)
    }
}

@Suite("Mail handoff: contact snapshot")
struct MailContactSnapshotTests {

    private let ada = MailContactSummary(
        displayName: "Ada Lovelace", organization: "Analytical Engines", jobTitle: "Mathematician",
        thumbnail: Data([0xFF, 0xD8, 0xFF, 0x00]), highlightReasons: [.favoriteContact])
    private let charles = MailContactSummary(displayName: "Charles Babbage", organization: "Analytical Engines")

    @Test
    func filesASummaryOnceUnderEachNormalizedAddress() {
        var snapshot = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 0))
        snapshot.add(ada, forAddresses: ["Ada@Example.com", "ada@example.com", "not an address", "ada@work.example"])

        #expect(snapshot.summariesByAddress.keys.sorted() == ["ada@example.com", "ada@work.example"])
        #expect(snapshot.summariesByAddress["ada@example.com"] == [ada])
        #expect(snapshot.summaries(forAddress: "Ada Lovelace <ADA@example.com>") == [ada])
        #expect(snapshot.summaries(forAddress: "stranger@example.com").isEmpty)
        #expect(snapshot.summaries(forAddress: "not an address").isEmpty)
    }

    @Test
    func sharedAddressReturnsEverySummary() {
        var snapshot = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 0))
        snapshot.add(ada, forAddresses: ["office@example.com"])
        snapshot.add(charles, forAddresses: ["office@example.com", "charles@example.com"])

        let shared = snapshot.summaries(forAddress: "office@example.com")
        #expect(shared == [ada, charles])
        let sharedIsHighlighted = shared.contains { $0.isHighlighted }
        #expect(sharedIsHighlighted)
        let charlesIsHighlighted = snapshot.summaries(forAddress: "charles@example.com").contains { $0.isHighlighted }
        #expect(charlesIsHighlighted == false)
    }

    @Test
    func storeRoundTripsAndPicksUpRewrites() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MailContactCacheStore(fileURL: directory.appendingPathComponent("Mail/contact-cache.plist"))

        #expect(try store.read() == nil)

        var first = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))
        first.add(ada, forAddresses: ["ada@example.com"])
        try store.write(first)
        #expect(try store.read() == .current(first))
        // A second read with no rewrite answers from the memo; still equal.
        #expect(try store.read() == .current(first))

        var second = first
        second.add(charles, forAddresses: ["charles@example.com"])
        try store.write(second)
        #expect(try store.read() == .current(second))
    }

    @Test
    func unknownHighlightReasonStillHighlights() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contact-cache.plist")
        try writePropertyList([
            "version": MailContactSnapshot.currentVersion,
            "generatedAt": Date(timeIntervalSince1970: 0),
            "summariesByAddress": [
                "grace@example.com": [
                    ["displayName": "Grace Hopper", "highlightReasons": ["favoriteTeam"], "pronouns": "she/her"],
                ],
            ],
        ], to: url)

        let contents = try #require(try MailContactCacheStore(fileURL: url).read())
        let summaries = contents.summaries(forAddress: "grace@example.com")
        #expect(summaries.count == 1)
        #expect(summaries.first?.highlightReasons == [MailHighlightReason(rawValue: "favoriteTeam")])
        #expect(summaries.first?.isHighlighted == true)
    }

    @Test
    func cacheWrittenBeforeDetailFieldsStillDecodes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contact-cache.plist")
        try writePropertyList([
            "version": MailContactSnapshot.currentVersion,
            "generatedAt": Date(timeIntervalSince1970: 0),
            "summariesByAddress": [
                "ada@example.com": [
                    ["displayName": "Ada Lovelace", "highlightReasons": [String]()],
                ],
            ],
        ], to: url)

        let contents = try #require(try MailContactCacheStore(fileURL: url).read())
        let summary = try #require(contents.summaries(forAddress: "ada@example.com").first)
        #expect(summary.displayName == "Ada Lovelace")
        #expect(summary.contactID == nil)
        #expect(summary.emailAddresses.isEmpty)
        #expect(summary.phoneNumbers.isEmpty)
        #expect(summary.birthday == nil)
    }

    @Test
    func detailFieldsRoundTripThroughTheStore() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MailContactCacheStore(fileURL: directory.appendingPathComponent("contact-cache.plist"))
        let detailed = MailContactSummary(
            displayName: "Ada Lovelace",
            contactID: "40000000-0000-4000-8000-000000000004",
            emailAddresses: [MailLabeledValue(label: "work", value: "ada@example.com")],
            phoneNumbers: [MailLabeledValue(label: "mobile", value: "555-0100")],
            birthday: "December 10, 1815")
        var snapshot = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 0))
        snapshot.add(detailed, forAddresses: ["ada@example.com"])

        try store.write(snapshot)
        #expect(try store.read() == .current(snapshot))
    }

    @Test
    func newerFormatStillNamesKnownAddresses() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contact-cache.plist")
        try writePropertyList([
            "version": 99,
            "summariesByAddress": ["ada@example.com": ["reshaped": true]],
        ], to: url)

        let contents = try #require(try MailContactCacheStore(fileURL: url).read())
        #expect(contents == .newerFormat(version: 99, knownAddresses: ["ada@example.com"]))
        #expect(contents.isKnown(address: "Ada <ADA@example.com>"))
        #expect(contents.isKnown(address: "stranger@example.com") == false)
        #expect(contents.summaries(forAddress: "ada@example.com").isEmpty)
    }

    @Test
    func newerFormatWithoutAnAddressIndexIsUnsupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contact-cache.plist")
        try writePropertyList(["version": 99, "people": [String]()], to: url)
        let store = MailContactCacheStore(fileURL: url)

        #expect(throws: MailHandoffError.unsupportedVersion(99)) { try store.read() }
        // The failure is remembered for this file version…
        #expect(throws: MailHandoffError.unsupportedVersion(99)) { try store.read() }

        // …but a republished file is decoded afresh.
        var snapshot = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 0))
        snapshot.add(ada, forAddresses: ["ada@example.com"])
        try store.write(snapshot)
        #expect(try store.read() == .current(snapshot))
    }

    private func writePropertyList(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }
}

@Suite("Mail handoff: flag color")
struct MailFlagColorTests {

    @Test
    func noReasonMeansNoFlag() {
        #expect(MailFlagColor.color(for: []) == nil)
    }

    @Test
    func eachReasonHasItsOwnColor() {
        #expect(MailFlagColor.color(for: [.favoriteContact]) == .blue)
        #expect(MailFlagColor.color(for: [.favoriteGroupMember]) == .green)
        #expect(MailFlagColor.color(for: [.favoriteOrganizationMember]) == .orange)
    }

    @Test
    func personBeatsGroupBeatsOrganization() {
        #expect(MailFlagColor.color(for: [.favoriteContact, .favoriteGroupMember, .favoriteOrganizationMember]) == .blue)
        #expect(MailFlagColor.color(for: [.favoriteGroupMember, .favoriteOrganizationMember]) == .green)
    }

    @Test
    func unrecognizedReasonStillFlagsWithMailsDefaultColor() {
        #expect(MailFlagColor.color(for: [MailHighlightReason(rawValue: "favoriteTeam")]) == .mailDefault)
        // A known reason still wins over an unknown one.
        #expect(MailFlagColor.color(for: [MailHighlightReason(rawValue: "favoriteTeam"), .favoriteGroupMember]) == .green)
    }
}

@Suite("Mail handoff: open-contact link")
struct MailContactLinkTests {

    private let id = "40000000-0000-4000-8000-000000000004"

    @Test
    func urlRoundTripsTheContactID() throws {
        let url = try #require(MailContactLink.url(scheme: "guesswho-linkedin-debug", contactID: id.uppercased()))
        #expect(url.absoluteString == "guesswho-linkedin-debug://open-contact?id=\(id)")
        #expect(MailContactLink.contactID(from: url, scheme: "guesswho-linkedin-debug") == id)
    }

    @Test
    func urlRefusesAnIDThatIsNotAUUID() {
        #expect(MailContactLink.url(scheme: "guesswho-linkedin", contactID: "not-a-uuid") == nil)
        #expect(MailContactLink.url(scheme: "guesswho-linkedin", contactID: "") == nil)
    }

    @Test
    func parsingRejectsOtherSchemesHostsAndIDs() throws {
        let scheme = "guesswho-linkedin"
        #expect(MailContactLink.contactID(from: try #require(URL(string: "other://open-contact?id=\(id)")), scheme: scheme) == nil)
        #expect(MailContactLink.contactID(from: try #require(URL(string: "\(scheme)://import-guide?id=\(id)")), scheme: scheme) == nil)
        #expect(MailContactLink.contactID(from: try #require(URL(string: "\(scheme)://open-contact")), scheme: scheme) == nil)
        #expect(MailContactLink.contactID(from: try #require(URL(string: "\(scheme)://open-contact?id=oops")), scheme: scheme) == nil)
    }
}

@Suite("Mail handoff: Message-ID")
struct MailMessageIDTests {

    @Test(arguments: [
        ("<abc.123@mail.example.com>", "<abc.123@mail.example.com>"),
        ("  <abc.123@mail.example.com>\r\n", "<abc.123@mail.example.com>"),
        ("abc.123@mail.example.com", "<abc.123@mail.example.com>"),
        ("(sent by) <abc@example.com> (relay)", "<abc@example.com>"),
        ("<CaseMatters@Example.com>", "<CaseMatters@Example.com>"),
    ])
    func normalizes(_ testCase: (header: String, expected: String)) {
        #expect(MailMessageID.normalize(testCase.header) == testCase.expected)
    }

    @Test(arguments: ["", "   ", "<>", "<abc@example.com", "abc def@example.com", "<abc def@example.com>"])
    func rejectsUnusableHeaders(_ header: String) {
        #expect(MailMessageID.normalize(header) == nil)
    }

    @Test
    func buildsMailLinkFromASafeID() {
        #expect(MailMessageID.mailDeepLink(for: "<abc.123@mail.example.com>")?.absoluteString
            == "message://%3Cabc.123@mail.example.com%3E")
    }

    @Test
    func percentEncodesAtextPunctuation() {
        #expect(MailMessageID.mailDeepLink(for: "<CAB+x=y/z%1@mail.gmail.com>")?.absoluteString
            == "message://%3CCAB%2Bx%3Dy%2Fz%251@mail.gmail.com%3E")
    }

    @Test(arguments: [
        "abc@example.com",
        "<abc>",
        "<abc@>",
        "<@example.com>",
        "<\"quoted\"@example.com>",
        "<abc@[192.0.2.1]>",
        "<abc@example..com>",
        "<.abc@example.com>",
        "<abc@example.com@relay>",
        "<ünï@example.com>",
    ])
    func refusesUnsafeIDs(_ messageID: String) {
        #expect(MailMessageID.isSyntacticallySafe(messageID) == false)
        #expect(MailMessageID.mailDeepLink(for: messageID) == nil)
    }
}

@Suite("Mail handoff: incoming-message journal")
struct MailIncomingJournalTests {

    private func entry(_ id: String, subject: String? = "Hello") -> MailIncomingMessage {
        let messageID = "<\(id)@example.com>"
        return MailIncomingMessage(
            sender: "ada@example.com",
            subject: subject,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageID: messageID,
            messageURL: MailMessageID.mailDeepLink(for: messageID))
    }

    @Test
    func appendDeduplicatesByMessageID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("Mail/journal.jsonl"))

        #expect(try journal.append(entry("one")) == .appended)
        #expect(try journal.append(entry("one", subject: "Re: Hello")) == .duplicate)
        #expect(try journal.append(entry("two")) == .appended)

        let claim = try #require(try journal.claimEntries())
        #expect(claim.entries == [entry("one"), entry("two")])
    }

    @Test
    func claimIsExclusiveAndAcknowledgeRemoves() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))
        try journal.append(entry("one"))
        try journal.append(entry("two"))

        let first = try #require(try journal.claimEntries())
        let firstIDs = first.entries.map { $0.messageID }
        #expect(firstIDs == ["<one@example.com>", "<two@example.com>"])
        // A second claimer (another app copy) gets nothing already held…
        #expect(try journal.claimEntries() == nil)
        // …and a claimed entry still de-duplicates new deliveries.
        #expect(try journal.append(entry("one")) == .duplicate)

        try journal.append(entry("three"))
        let second = try #require(try journal.claimEntries())
        #expect(second.entries == [entry("three")])

        try journal.acknowledge(first)
        #expect(try journal.claimEntries() == nil)
        // Acknowledged entries are gone, so a re-delivery is new again.
        #expect(try journal.append(entry("one")) == .appended)
    }

    @Test
    func releaseReturnsEntriesToThePool() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))
        try journal.append(entry("one"))

        let first = try #require(try journal.claimEntries())
        try journal.release(first)
        let second = try #require(try journal.claimEntries())
        #expect(second.entries == [entry("one")])
        #expect(second.token != first.token)
    }

    @Test
    func expiredClaimCanBeRetaken() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(
            fileURL: directory.appendingPathComponent("journal.jsonl"), claimLease: 60)
        try journal.append(entry("one"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let stale = try #require(try journal.claimEntries(now: start))
        #expect(try journal.claimEntries(now: start.addingTimeInterval(30)) == nil)
        let retaken = try #require(try journal.claimEntries(now: start.addingTimeInterval(61)))
        #expect(retaken.entries == [entry("one")])

        // The stale claimer is fenced off the retaken entry, and is told so.
        let staleAcknowledge = try journal.acknowledge(stale)
        #expect(staleAcknowledge == .init(applied: [], lost: ["<one@example.com>"], settledOrMissing: []))
        let staleRenew = try journal.renew(stale, now: start.addingTimeInterval(62))
        #expect(staleRenew.lostOwnership)
        let staleRelease = try journal.release(stale)
        #expect(staleRelease.lostOwnership)
        #expect(try journal.claimEntries(now: start.addingTimeInterval(63)) == nil)

        #expect(try journal.append(entry("one")) == .duplicate)
        let retakenAcknowledge = try journal.acknowledge(retaken)
        #expect(retakenAcknowledge == .init(applied: ["<one@example.com>"], lost: [], settledOrMissing: []))
        // Once another claimer has settled it, the stale claim hears
        // "settled", not "lost" — nobody owns it any more.
        let afterSettle = try journal.acknowledge(stale)
        #expect(afterSettle == .init(applied: [], lost: [], settledOrMissing: ["<one@example.com>"]))
        #expect(try journal.append(entry("one")) == .appended)
    }

    @Test
    func renewalKeepsTheLease() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(
            fileURL: directory.appendingPathComponent("journal.jsonl"), claimLease: 60)
        try journal.append(entry("one"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let claim = try #require(try journal.claimEntries(now: start))
        let renewed = try journal.renew(claim, now: start.addingTimeInterval(50))
        #expect(renewed == .init(applied: ["<one@example.com>"], lost: [], settledOrMissing: []))
        // Without the renewal the lease would have lapsed at +60.
        #expect(try journal.claimEntries(now: start.addingTimeInterval(100)) == nil)
        // It lapses one lease after the renewal instead.
        #expect(try journal.claimEntries(now: start.addingTimeInterval(111)) != nil)
    }

    @Test
    func claimsAreBounded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))
        for index in 0..<60 {
            try journal.append(entry("m\(index)"))
        }

        let small = try #require(try journal.claimEntries(limit: 2))
        let smallIDs = small.entries.map { $0.messageID }
        #expect(smallIDs == ["<m0@example.com>", "<m1@example.com>"])

        let standard = try #require(try journal.claimEntries())
        #expect(standard.entries.count == MailIncomingJournal.defaultClaimLimit)
        #expect(standard.entries.first?.messageID == "<m2@example.com>")

        let rest = try #require(try journal.claimEntries())
        #expect(rest.entries.count == 60 - 2 - MailIncomingJournal.defaultClaimLimit)
    }

    @Test
    func settlesByMessageIDSubset() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))
        try journal.append(entry("one"))
        try journal.append(entry("two"))
        try journal.append(entry("three"))
        let claim = try #require(try journal.claimEntries())

        let stored = try journal.acknowledge(claim, messageIDs: ["<one@example.com>"])
        #expect(stored == .init(applied: ["<one@example.com>"], lost: [], settledOrMissing: []))
        // One entry fails to store; only it goes back for a retry.
        let failed = try journal.release(claim, messageIDs: ["<two@example.com>"])
        #expect(failed == .init(applied: ["<two@example.com>"], lost: [], settledOrMissing: []))

        let retry = try #require(try journal.claimEntries())
        #expect(retry.entries == [entry("two")])

        // Settling the rest of the batch touches only what the claim still
        // holds. The entry it already acknowledged is "settled"; only the
        // one another claim now holds is "lost".
        let rest = try journal.acknowledge(claim)
        #expect(rest == .init(
            applied: ["<three@example.com>"],
            lost: ["<two@example.com>"],
            settledOrMissing: ["<one@example.com>"]))
        let retried = try journal.acknowledge(retry)
        #expect(retried == .init(applied: ["<two@example.com>"], lost: [], settledOrMissing: []))
        #expect(try journal.claimEntries() == nil)
    }

    @Test
    func settlingTheRestAfterSubsetsIsNotLostOwnership() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))
        try journal.append(entry("one"))
        try journal.append(entry("two"))
        try journal.append(entry("three"))
        let claim = try #require(try journal.claimEntries())

        try journal.acknowledge(claim, messageIDs: ["<one@example.com>"])
        try journal.release(claim, messageIDs: ["<two@example.com>"])

        // The caller can settle exactly the IDs it has left…
        let remaining = try journal.acknowledge(claim, messageIDs: ["<three@example.com>"])
        #expect(remaining == .init(applied: ["<three@example.com>"], lost: [], settledOrMissing: []))

        // …and a later whole-claim settle reports its own earlier settlements
        // as settled, never as someone else's.
        let whole = try journal.acknowledge(claim)
        #expect(whole == .init(
            applied: [], lost: [],
            settledOrMissing: ["<one@example.com>", "<two@example.com>", "<three@example.com>"]))
        #expect(whole.lostOwnership == false)

        // An ID that was never in the journal is missing, not lost.
        let unknown = try journal.release(claim, messageIDs: ["<never@example.com>"])
        #expect(unknown == .init(applied: [], lost: [], settledOrMissing: ["<never@example.com>"]))
    }

    @Test
    func claimEditsKeepKeysThisBuildDoesNotKnow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.jsonl")
        let known = entry("one")
        // A current-version line from a newer build that added keys.
        var entryObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        entryObject["futureField"] = "kept"
        let line: [String: Any] = ["entry": entryObject, "futureTop": ["nested": 1]]
        try (JSONSerialization.data(withJSONObject: line) + Data("\n".utf8)).write(to: url)
        let journal = MailIncomingJournal(fileURL: url)

        let claim = try #require(try journal.claimEntries())
        #expect(claim.entries == [known])
        let claimed = try onlyLineObject(at: url)
        #expect(claimed["claim"] != nil)
        #expect((claimed["entry"] as? [String: Any])?["futureField"] as? String == "kept")
        #expect((claimed["futureTop"] as? [String: Any])?["nested"] as? Int == 1)

        try journal.renew(claim)
        try journal.release(claim)
        let released = try onlyLineObject(at: url)
        #expect(released["claim"] == nil)
        #expect((released["entry"] as? [String: Any])?["futureField"] as? String == "kept")
        #expect((released["futureTop"] as? [String: Any])?["nested"] as? Int == 1)

        let again = try #require(try journal.claimEntries())
        #expect(again.entries == [known])
    }

    @Test
    func retentionNeverEvictsLiveClaims() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(
            fileURL: directory.appendingPathComponent("journal.jsonl"), maximumEntryCount: 3)
        try journal.append(entry("one"))
        try journal.append(entry("two"))
        try journal.append(entry("three"))
        let claim = try #require(try journal.claimEntries(limit: 2))

        // Over the cap, the oldest UNCLAIMED line goes: three, then four.
        #expect(try journal.append(entry("four")) == .appended)
        #expect(try journal.append(entry("three")) == .appended)

        let settled = try journal.acknowledge(claim)
        #expect(settled == .init(
            applied: ["<one@example.com>", "<two@example.com>"], lost: [], settledOrMissing: []))
        let rest = try #require(try journal.claimEntries())
        #expect(rest.entries == [entry("three")])
    }

    @Test
    func appendIsDroppedWhenOnlyLiveClaimsRemain() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.jsonl")
        let journal = MailIncomingJournal(fileURL: url, maximumEntryCount: 2)
        try journal.append(entry("one"))
        try journal.append(entry("two"))
        let claim = try #require(try journal.claimEntries())
        let before = try Data(contentsOf: url)

        #expect(try journal.append(entry("three")) == .droppedForCapacity)
        #expect(try Data(contentsOf: url) == before)

        try journal.acknowledge(claim)
        #expect(try journal.append(entry("three")) == .appended)
    }

    @Test
    func byteCapBoundsTheFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.jsonl")
        try MailIncomingJournal(fileURL: url).append(entry("m0"))
        let lineBytes = try Data(contentsOf: url).count
        try FileManager.default.removeItem(at: url)

        let journal = MailIncomingJournal(fileURL: url, maximumByteCount: lineBytes * 3 + lineBytes / 2)
        for index in 0..<10 {
            #expect(try journal.append(entry("m\(index)")) == .appended)
        }
        #expect(try Data(contentsOf: url).count <= journal.maximumByteCount)
        let claim = try #require(try journal.claimEntries())
        let claimedIDs = claim.entries.map { $0.messageID }
        #expect(claimedIDs == ["<m7@example.com>", "<m8@example.com>", "<m9@example.com>"])

        // A single entry bigger than the whole cap is dropped, not written.
        let tiny = MailIncomingJournal(
            fileURL: directory.appendingPathComponent("tiny.jsonl"), maximumByteCount: lineBytes / 2)
        #expect(try tiny.append(entry("big")) == .droppedForCapacity)
    }

    private func message(
        sender: String = "ada@example.com", subject: String? = nil, id: String, messageURL: URL? = nil
    ) -> MailIncomingMessage {
        MailIncomingMessage(
            sender: sender, subject: subject, receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageID: id.hasPrefix("<") ? id : "<\(id)@example.com>", messageURL: messageURL)
    }

    @Test
    func subjectIsClippedInUTF8BytesAtCharacterBoundaries() {
        let limit = MailIncomingMessage.maximumSubjectUTF8Length

        let ascii = message(subject: String(repeating: "s", count: 2_000), id: "ascii")
        #expect(ascii.subject == String(repeating: "s", count: limit))

        // Four-byte scalars: whole emoji only, never a split scalar.
        let emoji = message(subject: String(repeating: "😀", count: 400), id: "emoji")
        #expect(emoji.subject == String(repeating: "😀", count: limit / 4))

        // "e" + COMBINING ACUTE ACCENT is one three-byte character; the mark
        // is never cut off its base.
        let combining = message(subject: String(repeating: "e\u{301}", count: 400), id: "combining")
        #expect(combining.subject == String(repeating: "e\u{301}", count: limit / 3))
        #expect(combining.subject?.unicodeScalars.last == "\u{301}")
        let combiningBytes = combining.subject?.utf8.count ?? 0
        #expect(combiningBytes <= limit)

        // One character bigger than the whole limit leaves no subject at all.
        let oneHugeCharacter = message(subject: "z" + String(repeating: "\u{301}", count: limit), id: "huge")
        #expect(oneHugeCharacter.subject == nil)

        // Under the limit, the subject is kept exactly.
        let short = message(subject: "Caf\u{E9} \u{1F600}", id: "short")
        #expect(short.subject == "Caf\u{E9} \u{1F600}")
    }

    @Test
    func senderAndMessageIDAreBoundedInUTF8Bytes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))

        // 212 characters but 412 bytes: over the 320-byte address bound.
        let wideAddress = String(repeating: "\u{E9}", count: 200) + "@example.com"
        #expect(wideAddress.count <= MailAddressNormalizer.maximumUTF8Length)
        #expect(MailAddressNormalizer.normalize(wideAddress) == nil)
        #expect(throws: MailHandoffError.invalidEntry) {
            try journal.append(message(sender: wideAddress, id: "wide-sender"))
        }

        // 514 characters but 1,014 bytes: over the 986-byte Message-ID bound.
        let wideID = "<" + String(repeating: "\u{E9}", count: 500) + "@example.com>"
        #expect(wideID.count <= MailMessageID.maximumUTF8Length)
        #expect(MailMessageID.normalize(wideID) == nil)
        #expect(throws: MailHandoffError.invalidEntry) { try journal.append(message(id: wideID)) }

        let overlongLink = message(id: "link", messageURL: URL(string: "message://" + String(repeating: "u", count: 5_000)))
        #expect(overlongLink.messageURL == nil)
        #expect(try journal.append(overlongLink) == .appended)
    }

    @Test
    func worstCaseEntryFitsTheLineCap() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(fileURL: directory.appendingPathComponent("journal.jsonl"))

        // Every field at its byte bound, filled with what JSON escapes most
        // expensively: control characters (6 bytes each) and quotes (2).
        let linkCount = (MailIncomingMessage.maximumMessageURLUTF8Length - "message://".utf8.count) / 3
        let worst = message(
            sender: String(repeating: "\"", count: MailAddressNormalizer.maximumUTF8Length - 12) + "@example.com",
            subject: String(repeating: "\u{1}", count: MailIncomingMessage.maximumSubjectUTF8Length),
            id: "<" + String(repeating: "\"", count: MailMessageID.maximumUTF8Length - 14) + "@example.com>",
            messageURL: URL(string: "message://" + String(repeating: "%25", count: linkCount)))
        #expect(worst.subject?.utf8.count == MailIncomingMessage.maximumSubjectUTF8Length)
        #expect(worst.messageURL != nil)

        #expect(try journal.append(worst) == .appended)
        let lineBytes = try Data(contentsOf: journal.fileURL).count - 1
        #expect(lineBytes <= MailIncomingJournal.defaultMaximumLineByteCount)
    }

    @Test
    func oversizedLineIsRefusedBeforeAnyEviction() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.jsonl")
        try MailIncomingJournal(fileURL: url).append(entry("one"))
        try MailIncomingJournal(fileURL: url).append(entry("two"))
        let before = try Data(contentsOf: url)

        // A tiny line cap stands in for an entry that slipped past the field
        // bounds; the full journal would otherwise evict to make room.
        let strict = MailIncomingJournal(fileURL: url, maximumEntryCount: 2, maximumLineByteCount: 64)
        #expect(throws: MailHandoffError.entryTooLarge) { try strict.append(entry("three")) }
        #expect(try Data(contentsOf: url) == before)
    }

    /// Appenders and claimers race on one file from separate threads, each
    /// with its own journal value — and every call its own
    /// `NSFileCoordinator` — the way the extension and two app copies would.
    @Test
    func concurrentAppendsAndClaimsNeitherLoseNorDoubleClaim() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.jsonl")
        let total = 120
        let appenderCount = 4
        let claimerCount = 3
        let recorder = ConcurrencyRecorder()

        DispatchQueue.concurrentPerform(iterations: appenderCount + claimerCount) { worker in
            let journal = MailIncomingJournal(fileURL: url)
            do {
                if worker < appenderCount {
                    // Counted as finished even when an append throws, so the
                    // claimers stop and the recorded error fails the test
                    // instead of the claimers spinning forever.
                    defer { recorder.finishAppender() }
                    for index in stride(from: worker, to: total, by: appenderCount) {
                        recorder.recordAppend(try journal.append(entry("c\(index)")))
                    }
                } else {
                    while true {
                        // Read before claiming: once every append has landed,
                        // an empty claim means nothing unclaimed is left.
                        let appendsDone = recorder.finishedAppenders == appenderCount
                        guard let claim = try journal.claimEntries(limit: 7) else {
                            if appendsDone { break }
                            Thread.sleep(forTimeInterval: 0.001)
                            continue
                        }
                        recorder.recordClaim(claim.entries.map { $0.messageID })
                        recorder.recordLost(try journal.acknowledge(claim).lost)
                    }
                }
            } catch {
                recorder.recordError(error)
            }
        }

        let result = recorder.result()
        #expect(result.errors.isEmpty)
        #expect(result.appended == total)
        #expect(result.claimed.count == total)
        #expect(Set(result.claimed) == Set((0..<total).map { "<c\($0)@example.com>" }))
        #expect(result.lost.isEmpty)
        #expect(try MailIncomingJournal(fileURL: url).claimEntries() == nil)
    }

    private func onlyLineObject(at url: URL) throws -> [String: Any] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test
    func keepsOnlyTheNewestEntries() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = MailIncomingJournal(
            fileURL: directory.appendingPathComponent("journal.jsonl"), maximumEntryCount: 2)
        try journal.append(entry("one"))
        try journal.append(entry("two"))
        try journal.append(entry("three"))

        let claim = try #require(try journal.claimEntries())
        let claimedIDs = claim.entries.map { $0.messageID }
        #expect(claimedIDs == ["<two@example.com>", "<three@example.com>"])
    }

    @Test
    func undecodableLinesSurviveEveryRewrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.jsonl")
        let futureLine = #"{"entry":{"messageID":"<future@example.com>","novel":true,"version":99}}"#
        try Data((futureLine + "\n").utf8).write(to: url)
        let journal = MailIncomingJournal(fileURL: url)

        #expect(try journal.append(entry("one")) == .appended)
        // A newer build's entry still counts for de-duplication…
        #expect(try journal.append(MailIncomingMessage(
            sender: "ada@example.com", subject: nil, receivedAt: Date(),
            messageID: "<future@example.com>", messageURL: nil)) == .duplicate)
        // …but is never claimed by this build, and outlives the acknowledgement.
        let claim = try #require(try journal.claimEntries())
        #expect(claim.entries == [entry("one")])
        try journal.acknowledge(claim)

        let remaining = try String(contentsOf: url, encoding: .utf8)
        #expect(remaining == futureLine + "\n")
    }

    @Test
    func appendPostsTheChangeNotification() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "com.milestonemade.guesswho.tests.mail-journal.\(UUID().uuidString)"
        let journal = MailIncomingJournal(
            fileURL: directory.appendingPathComponent("journal.jsonl"), changeNotificationName: name)

        let (posts, continuation) = AsyncStream<Void>.makeStream()
        let observer = MailJournalChangeNotification.Observer(name: name) { continuation.yield() }
        defer { withExtendedLifetime(observer) {} }

        try journal.append(entry("one"))

        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in posts { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(received)
    }
}

/// Thread-safe tally for the concurrency test. `@unchecked Sendable`: every
/// stored property is read and written only while holding `lock`.
private final class ConcurrencyRecorder: @unchecked Sendable {
    struct Result {
        let appended: Int
        let claimed: [String]
        let lost: Set<String>
        let errors: [String]
    }

    private let lock = NSLock()
    private var appended = 0
    private var finished = 0
    private var claimed: [String] = []
    private var lost: Set<String> = []
    private var errors: [String] = []

    var finishedAppenders: Int { lock.withLock { finished } }

    func recordAppend(_ outcome: MailIncomingJournal.AppendOutcome) {
        lock.withLock {
            if outcome == .appended {
                appended += 1
            } else {
                errors.append("append outcome \(outcome)")
            }
        }
    }

    func finishAppender() { lock.withLock { finished += 1 } }
    func recordClaim(_ ids: [String]) { lock.withLock { claimed += ids } }
    func recordLost(_ ids: Set<String>) { lock.withLock { lost.formUnion(ids) } }
    func recordError(_ error: any Error) { lock.withLock { errors.append(String(describing: error)) } }

    func result() -> Result {
        lock.withLock { Result(appended: appended, claimed: claimed, lost: lost, errors: errors) }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailHandoffTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
