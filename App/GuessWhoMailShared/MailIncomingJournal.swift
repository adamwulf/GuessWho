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
/// still carry this claim's token, and its `ClaimOutcome` names the entries
/// the claim no longer holds (`lost`) — its lease lapsed and another claimer
/// took them, or they are gone. A claimer that sees `lost` entries must treat
/// them as someone else's. A lapsed claim whose entries nobody has retaken
/// still settles them.
///
/// ## Format
/// JSON Lines. Each line is a JSON object `{"entry": <MailIncomingMessage>,
/// "claim": {"token": <UUID>, "claimedAt": <seconds since 2001>}}`, with
/// `claim` absent when unclaimed. Claiming, renewing, and releasing change
/// only the `claim` member of a line's JSON object; every other member —
/// including keys this build doesn't know inside `entry` — is written back
/// as it was read. A line whose `entry` this build can't decode (a newer
/// entry version, or damage) is never claimed and is kept byte-for-byte, so
/// an older build never destroys a newer build's entries. The `claim` shape
/// is fixed across versions: builds read each other's claims.
///
/// ## Retention
/// The file holds at most `maximumEntryCount` lines and `maximumByteCount`
/// bytes. Appending past either evicts the oldest lines that no live claim
/// holds; live claimed lines are never evicted. If the new entry can't fit
/// even then, it is dropped (`AppendOutcome.droppedForCapacity`) and the file
/// is left alone. Untrusted text is bounded before it gets here: subjects
/// are clipped to `MailIncomingMessage.maximumSubjectLength`, and `append`
/// rejects over-long senders and Message-IDs.
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
    /// The most lines the file keeps.
    let maximumEntryCount: Int
    /// The most bytes the file keeps (newlines included).
    let maximumByteCount: Int
    /// How long a claim holds its entries without a `renew`.
    let claimLease: TimeInterval
    /// The Darwin notification posted after each successful append, or nil
    /// to post nothing (tests). See `MailJournalChangeNotification`.
    let changeNotificationName: String?

    static let defaultMaximumEntryCount = 2_000
    static let defaultMaximumByteCount = 2 * 1024 * 1024
    static let defaultClaimLease: TimeInterval = 5 * 60
    static let defaultClaimLimit = 50

    init(
        fileURL: URL,
        maximumEntryCount: Int = defaultMaximumEntryCount,
        maximumByteCount: Int = defaultMaximumByteCount,
        claimLease: TimeInterval = defaultClaimLease,
        changeNotificationName: String? = nil
    ) {
        self.fileURL = fileURL
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumByteCount = max(1, maximumByteCount)
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
    /// over-long sender or Message-ID.
    @discardableResult
    func append(_ entry: MailIncomingMessage) throws -> AppendOutcome {
        try Self.validate(entry)
        let newLine = try Line(appending: entry)
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

    /// What a `renew`, `acknowledge`, or `release` did.
    struct ClaimOutcome: Equatable, Sendable {
        /// Message-IDs the call acted on: lines still carrying the claim's
        /// token.
        let applied: Set<String>
        /// Message-IDs asked about that the claim no longer holds — the lease
        /// lapsed and another claimer took them, or they are gone. The caller
        /// no longer owns these and must not act on them as if it did.
        let lost: Set<String>

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
        guard !targets.isEmpty else { return ClaimOutcome(applied: [], lost: []) }
        return try MailFileCoordination.write(fileURL) { url in
            var applied = Set<String>()
            var kept: [Line] = []
            for var line in try Self.lines(at: url) {
                if let messageID = line.messageID, targets.contains(messageID),
                   line.claim?.token == claim.token {
                    applied.insert(messageID)
                    guard try change(&line) else { continue }
                }
                kept.append(line)
            }
            if !applied.isEmpty {
                try Self.write(kept, to: url)
            }
            return ClaimOutcome(applied: applied, lost: targets.subtracting(applied))
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

    private static func validate(_ entry: MailIncomingMessage) throws {
        guard !entry.sender.isEmpty,
              entry.sender.count <= MailAddressNormalizer.maximumLength,
              !entry.messageID.isEmpty,
              entry.messageID.count <= MailMessageID.maximumLength,
              (entry.subject?.count ?? 0) <= MailIncomingMessage.maximumSubjectLength
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
