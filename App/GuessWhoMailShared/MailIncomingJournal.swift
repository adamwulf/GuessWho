import Foundation

/// The incoming-message journal: the Mail extension appends one
/// `MailIncomingMessage` per message from a known sender, and the app drains
/// it with a claim → store → acknowledge transaction.
///
/// ## Draining
/// `claimEntries(limit:)` atomically marks up to `limit` of the oldest
/// entries that no live claim holds with a fresh claim token and returns
/// them. A second claimer — say, a Debug and an /Applications copy of the app
/// sharing the App Group — gets only entries nobody holds, so the two never
/// process the same entry at once.
///
/// The claimer then settles each entry, all at once or by Message-ID subset
/// (so one entry that can't be stored doesn't hold back or replay the rest):
/// `acknowledge` removes entries it has stored or deliberately dropped,
/// `release` hands entries back for a later claim, and `renew` restarts the
/// lease during a long drain. A claim that is never settled (the app quit
/// mid-drain) expires after `claimLease`, and its entries become claimable
/// again.
///
/// Every settle call is fenced by the claim token: it touches only lines that
/// still carry this claim's token. Its `ClaimOutcome` sorts every Message-ID
/// asked about into `applied` (held by this claim; acted on), `lost` (in the
/// journal but held by a different claim token — this claim's lease lapsed
/// and another claimer took them), and `settledOrMissing` (held by no claim:
/// already acknowledged or released, evicted, or never there). Only `lost`
/// entries are someone else's. A lapsed claim whose entries nobody has
/// retaken still settles them.
///
/// ## Format
/// JSON Lines. Each line is a JSON object `{"entry": <MailIncomingMessage>,
/// "claim": {"token": <UUID>, "claimedAt": <seconds since 2001>}}`, with
/// `claim` absent when unclaimed. Claiming, renewing, and releasing change
/// only the `claim` member of a line's JSON object; every other member —
/// including keys this build doesn't know inside `entry` — is written back
/// as it was read. A line whose `entry` this build can't decode (a newer
/// entry version, or damage) is never claimed and is carried byte-for-byte
/// through every claim, settle, and append this build performs; like any
/// unclaimed line, though, retention may evict it to make room. The `claim`
/// shape is fixed across versions: builds read each other's claims.
///
/// ## Retention
/// `append` keeps the file within `maximumEntryCount` lines and
/// `maximumByteCount` bytes by evicting the oldest lines that no live claim
/// holds; live claimed lines are never evicted. If the new entry can't fit
/// even then, it is dropped (`AppendOutcome.droppedForCapacity`) and the file
/// is left alone. The caps are enforced only at append: claiming and renewing
/// add claim metadata to lines without re-checking them, so a file full of
/// claimed lines can briefly exceed `maximumByteCount` by that metadata.
///
/// Untrusted text is bounded in UTF-8 bytes before it gets here: subjects
/// are clipped (`MailIncomingMessage.maximumSubjectUTF8Length`), and `append`
/// rejects over-long senders and Message-IDs. As a backstop, `append` also
/// refuses any entry whose encoded line exceeds `maximumLineByteCount`
/// before it touches the file. That bounds, rather than prevents, what one
/// entry can evict: when the file sits at `maximumByteCount`, an accepted
/// entry still evicts the fewest oldest unclaimed lines that make room for
/// it — whole lines, so about its own size and at most about two line caps.
///
/// ## Concurrency
/// Every operation is one `NSFileCoordinator` claim on the file, and every
/// change is a read-modify-write inside a single coordinated write that
/// replaces the file atomically. Concurrent appends, claims, and settles —
/// from any process or thread — serialize; none loses another's change.
///
/// ## De-duplication
/// Entries are unique by `messageID` among the lines currently in the file,
/// claimed or not. Once an entry is acknowledged it is gone, and a later
/// delivery of the same message is appended again — the app's own store must
/// also de-duplicate by Message-ID.
struct MailIncomingJournal: Sendable {
    let fileURL: URL
    /// The most lines `append` keeps.
    let maximumEntryCount: Int
    /// The most bytes `append` keeps (newlines included). See "Retention".
    let maximumByteCount: Int
    /// The largest encoded line `append` accepts, in bytes (newline
    /// excluded). Every entry within the field bounds encodes well under the
    /// default, so this only stops an entry that slipped past them.
    let maximumLineByteCount: Int
    /// How long a claim holds its entries without a `renew`.
    let claimLease: TimeInterval
    /// The Darwin notification posted after each successful append, or nil
    /// to post nothing (tests). See `MailJournalChangeNotification`.
    let changeNotificationName: String?

    static let defaultMaximumEntryCount = 2_000
    static let defaultMaximumByteCount = 2 * 1_024 * 1_024
    static let defaultMaximumLineByteCount = 16 * 1_024
    static let defaultClaimLease: TimeInterval = 5 * 60
    static let defaultClaimLimit = 50

    init(
        fileURL: URL,
        maximumEntryCount: Int = defaultMaximumEntryCount,
        maximumByteCount: Int = defaultMaximumByteCount,
        maximumLineByteCount: Int = defaultMaximumLineByteCount,
        claimLease: TimeInterval = defaultClaimLease,
        changeNotificationName: String? = nil
    ) {
        self.fileURL = fileURL
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumByteCount = max(1, maximumByteCount)
        self.maximumLineByteCount = max(1, maximumLineByteCount)
        self.claimLease = claimLease
        self.changeNotificationName = changeNotificationName
    }

    /// The journal at the shared App Group location, posting the App Group's
    /// change notification, or nil when this bundle has no `GuessWhoAppGroup`
    /// Info.plist value.
    static func shared(in bundle: Bundle = .main) -> MailIncomingJournal? {
        guard let url = MailHandoffContainer.incomingJournalURL(in: bundle) else { return nil }
        return MailIncomingJournal(
            fileURL: url,
            changeNotificationName: MailJournalChangeNotification.name(in: bundle))
    }

    // MARK: - Appending (extension)

    enum AppendOutcome: Equatable, Sendable {
        case appended
        /// An entry with the same `messageID` is already in the journal; the
        /// file was left unchanged and no notification was posted.
        case duplicate
        /// The entry can't fit without evicting live claimed lines; the file
        /// was left unchanged and no notification was posted.
        case droppedForCapacity
    }

    /// Appends `entry` unless one with its `messageID` is already present,
    /// evicting the oldest unclaimed lines as needed, then posts the change
    /// notification. Throws `MailHandoffError.invalidEntry` for an empty or
    /// over-long sender, Message-ID, or subject, and
    /// `MailHandoffError.entryTooLarge` for an encoded line over
    /// `maximumLineByteCount` — both before the file is touched.
    @discardableResult
    func append(_ entry: MailIncomingMessage) throws -> AppendOutcome {
        try Self.validate(entry)
        let newLine = try Line(appending: entry)
        guard newLine.raw.count <= maximumLineByteCount else { throw MailHandoffError.entryTooLarge }
        let outcome: AppendOutcome = try MailFileCoordination.write(fileURL) { url in
            let lines = try Self.lines(at: url)
            if lines.contains(where: { $0.messageID == entry.messageID }) {
                return .duplicate
            }
            guard let retained = retaining(lines + [newLine], now: Date()) else {
                return .droppedForCapacity
            }
            try Self.write(retained, to: url)
            return .appended
        }
        if outcome == .appended, let changeNotificationName {
            MailJournalChangeNotification.post(name: changeNotificationName)
        }
        return outcome
    }

    // MARK: - Draining (app)

    /// Entries held by one `claimEntries(limit:now:)` call.
    struct Claim: Sendable {
        let token: UUID
        /// Oldest first.
        let entries: [MailIncomingMessage]
    }

    /// What a `renew`, `acknowledge`, or `release` did, with every Message-ID
    /// asked about in exactly one bucket.
    struct ClaimOutcome: Equatable, Sendable {
        /// Lines still carrying this claim's token; the call acted on them.
        let applied: Set<String>
        /// Lines in the journal held by a DIFFERENT claim token: this claim's
        /// lease lapsed and another claimer took them. The caller no longer
        /// owns these and must not act on them as if it did.
        let lost: Set<String>
        /// Held by no claim at all: already acknowledged or released (by this
        /// claim or another), evicted, or never in the journal. Nothing is
        /// left to do for these, and nobody else owns them.
        let settledOrMissing: Set<String>

        var lostOwnership: Bool { !lost.isEmpty }
    }

    /// Atomically claims up to `limit` of the oldest entries that no live
    /// claim holds. Nil when there is nothing to claim.
    func claimEntries(limit: Int = defaultClaimLimit, now: Date = Date()) throws -> Claim? {
        let limit = max(1, limit)
        let token = UUID()
        return try MailFileCoordination.write(fileURL) { url in
            var lines = try Self.lines(at: url)
            var claimed: [MailIncomingMessage] = []
            for index in lines.indices {
                guard claimed.count < limit else { break }
                guard let entry = lines[index].entry, !isLive(lines[index], now: now) else { continue }
                try lines[index].setClaim(StoredClaim(token: token, claimedAt: now))
                claimed.append(entry)
            }
            guard !claimed.isEmpty else { return nil }
            try Self.write(lines, to: url)
            return Claim(token: token, entries: claimed)
        }
    }

    /// Restarts the lease on the claim's entries (or the `messageIDs` subset
    /// of them) that it still holds.
    @discardableResult
    func renew(_ claim: Claim, messageIDs: Set<String>? = nil, now: Date = Date()) throws -> ClaimOutcome {
        try settle(claim, messageIDs: messageIDs) { line in
            try line.setClaim(StoredClaim(token: claim.token, claimedAt: now))
            return true
        }
    }

    /// Removes the claim's entries (or the `messageIDs` subset of them) that
    /// it still holds. Call once they are stored, or deliberately dropped.
    @discardableResult
    func acknowledge(_ claim: Claim, messageIDs: Set<String>? = nil) throws -> ClaimOutcome {
        try settle(claim, messageIDs: messageIDs) { _ in false }
    }

    /// Returns the claim's entries (or the `messageIDs` subset of them) that
    /// it still holds to the unclaimed pool, for a later claim to retry.
    @discardableResult
    func release(_ claim: Claim, messageIDs: Set<String>? = nil) throws -> ClaimOutcome {
        try settle(claim, messageIDs: messageIDs) { line in
            try line.setClaim(nil)
            return true
        }
    }

    /// Applies `change` to each targeted line that still carries the claim's
    /// token; `change` returns whether to keep the line.
    private func settle(
        _ claim: Claim, messageIDs: Set<String>?, _ change: (inout Line) throws -> Bool
    ) throws -> ClaimOutcome {
        let targets = messageIDs ?? Set(claim.entries.map(\.messageID))
        guard !targets.isEmpty else { return ClaimOutcome(applied: [], lost: [], settledOrMissing: []) }
        return try MailFileCoordination.write(fileURL) { url in
            var applied = Set<String>()
            var lost = Set<String>()
            var kept: [Line] = []
            for var line in try Self.lines(at: url) {
                if let messageID = line.messageID, targets.contains(messageID), let owner = line.claim {
                    if owner.token == claim.token {
                        applied.insert(messageID)
                        guard try change(&line) else { continue }
                    } else {
                        lost.insert(messageID)
                    }
                }
                kept.append(line)
            }
            if !applied.isEmpty {
                try Self.write(kept, to: url)
            }
            return ClaimOutcome(
                applied: applied,
                lost: lost,
                settledOrMissing: targets.subtracting(applied).subtracting(lost))
        }
    }

    // MARK: - Claims and retention

    /// A claim is live for `claimLease` either side of `now`, so a clock that
    /// jumps backwards can't pin entries for longer than one lease.
    private func isLive(_ line: Line, now: Date) -> Bool {
        guard let claim = line.claim else { return false }
        return abs(now.timeIntervalSince(claim.claimedAt)) < claimLease
    }

    /// `lines` (the new line last) trimmed to the caps by evicting the oldest
    /// lines no live claim holds, or nil when that can't make room without
    /// evicting the new line or a live claim.
    private func retaining(_ lines: [Line], now: Date) -> [Line]? {
        var count = lines.count
        var bytes = lines.reduce(0) { $0 + $1.byteCount }
        func fits() -> Bool { count <= maximumEntryCount && bytes <= maximumByteCount }
        guard !fits() else { return lines }

        var evicted = IndexSet()
        for index in lines.indices.dropLast() where !isLive(lines[index], now: now) {
            evicted.insert(index)
            count -= 1
            bytes -= lines[index].byteCount
            if fits() { break }
        }
        guard fits() else { return nil }
        return lines.indices.filter { !evicted.contains($0) }.map { lines[$0] }
    }

    /// Byte bounds on every sender-controlled field (the fields are `var`, so
    /// `MailIncomingMessage.init`'s clipping alone can't be relied on).
    private static func validate(_ entry: MailIncomingMessage) throws {
        guard !entry.sender.isEmpty,
              entry.sender.utf8.count <= MailAddressNormalizer.maximumUTF8Length,
              !entry.messageID.isEmpty,
              entry.messageID.utf8.count <= MailMessageID.maximumUTF8Length,
              (entry.subject?.utf8.count ?? 0) <= MailIncomingMessage.maximumSubjectUTF8Length,
              (entry.messageURL?.absoluteString.utf8.count ?? 0) <= MailIncomingMessage.maximumMessageURLUTF8Length
        else { throw MailHandoffError.invalidEntry }
    }

    // MARK: - Lines

    private struct StoredClaim: Equatable {
        let token: UUID
        let claimedAt: Date

        init(token: UUID, claimedAt: Date) {
            self.token = token
            self.claimedAt = claimedAt
        }

        /// Nil for a missing or unreadable `claim` member, which counts as
        /// unclaimed.
        init?(jsonValue: Any?) {
            guard let object = jsonValue as? [String: Any],
                  let tokenString = object["token"] as? String,
                  let token = UUID(uuidString: tokenString),
                  let seconds = (object["claimedAt"] as? NSNumber)?.doubleValue
            else { return nil }
            self.token = token
            self.claimedAt = Date(timeIntervalSinceReferenceDate: seconds)
        }

        var jsonValue: [String: Any] {
            ["token": token.uuidString, "claimedAt": claimedAt.timeIntervalSinceReferenceDate]
        }
    }

    private struct Line {
        /// The exact bytes of the line, without its newline.
        private(set) var raw: Data
        /// The line's top-level JSON object; nil when the line isn't one.
        private var object: [String: Any]?
        /// Nil when this build can't decode the line's entry.
        let entry: MailIncomingMessage?
        /// Present even for an undecodable entry that still carries a
        /// readable `messageID`, so de-duplication covers newer entries too.
        let messageID: String?
        private(set) var claim: StoredClaim?

        var byteCount: Int { raw.count + 1 }

        init(parsing raw: Data) {
            self.raw = raw
            let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            self.object = object
            let entryObject = object?["entry"] as? [String: Any]
            if let version = entryObject?["version"] as? Int, version <= MailIncomingMessage.currentVersion {
                entry = (try? JSONDecoder().decode(EntryEnvelope.self, from: raw))?.entry
            } else {
                entry = nil
            }
            messageID = entry?.messageID ?? entryObject?["messageID"] as? String
            claim = StoredClaim(jsonValue: object?["claim"])
        }

        init(appending entry: MailIncomingMessage) throws {
            self.init(parsing: try MailIncomingJournal.encoder.encode(EntryEnvelope(entry: entry)))
        }

        /// Rewrites only the `claim` member of the line's JSON object.
        mutating func setClaim(_ newClaim: StoredClaim?) throws {
            guard var object else { throw MailHandoffError.malformedJournalLine }
            if let newClaim {
                object["claim"] = newClaim.jsonValue
            } else {
                object.removeValue(forKey: "claim")
            }
            raw = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            self.object = object
            claim = newClaim
        }
    }

    private struct EntryEnvelope: Codable {
        let entry: MailIncomingMessage
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func lines(at url: URL) throws -> [Line] {
        guard let data = try MailFileCoordination.contentsIfPresent(of: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { slice in
            let raw = Data(slice)
            guard raw.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\r") }) else {
                return nil
            }
            return Line(parsing: raw)
        }
    }

    private static func write(_ lines: [Line], to url: URL) throws {
        var data = Data()
        for line in lines {
            data.append(line.raw)
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }
}

/// The Darwin notification the journal posts after each append, so a running
/// app can drain promptly instead of waiting for its next activation.
///
/// The name is derived from the App Group id (`<group>.mail.incoming-journal`)
/// — never hardcoded — following the App Group convention of prefixing
/// shared IPC names (Mach ports, POSIX semaphores) with the group id, so it
/// is namespaced to this app family. Darwin notifications carry no
/// payload and may coalesce, so an observer must treat one as "the journal
/// may have changed" and claim whatever is there; activation remains the
/// fallback.
enum MailJournalChangeNotification {

    static func name(in bundle: Bundle = .main) -> String? {
        MailHandoffContainer.appGroupIdentifier(in: bundle).map { "\($0).mail.incoming-journal" }
    }

    static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }

    /// Calls `handler` whenever the named notification is posted by any
    /// process, until this observer is deallocated. The handler may run on
    /// any thread.
    ///
    /// `@unchecked Sendable`: both stored properties are immutable after
    /// init, and the Darwin center only reads the unretained `self` pointer,
    /// which `deinit` unregisters before the memory goes away.
    final class Observer: @unchecked Sendable {
        let name: String
        private let handler: @Sendable () -> Void

        init(name: String, handler: @escaping @Sendable () -> Void) {
            self.name = name
            self.handler = handler
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    Unmanaged<Observer>.fromOpaque(observer).takeUnretainedValue().handler()
                },
                name as CFString,
                nil,
                .deliverImmediately)
        }

        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name as CFString),
                nil)
        }
    }
}
