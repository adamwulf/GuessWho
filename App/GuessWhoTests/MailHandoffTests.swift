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
        #expect(try store.read() == first)
        // A second read with no rewrite answers from the memo; still equal.
        #expect(try store.read() == first)

        var second = first
        second.add(charles, forAddresses: ["charles@example.com"])
        try store.write(second)
        #expect(try store.read() == second)
    }

    @Test
    func storeRefusesANewerFormat() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MailContactCacheStore(fileURL: directory.appendingPathComponent("contact-cache.plist"))

        var future = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 0))
        future.version = MailContactSnapshot.currentVersion + 1
        try store.write(future)

        #expect(throws: MailHandoffError.unsupportedVersion(MailContactSnapshot.currentVersion + 1)) {
            try store.read()
        }
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

        // The stale claimer's late acknowledgement leaves the retaken entry.
        try journal.acknowledge(stale)
        #expect(try journal.append(entry("one")) == .duplicate)
        try journal.acknowledge(retaken)
        #expect(try journal.append(entry("one")) == .appended)
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

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailHandoffTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
