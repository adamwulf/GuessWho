import Foundation

/// The incoming-message journal: the Mail extension appends one
/// `MailIncomingMessage` per message from a known sender, and the app drains
/// it with a claim → store → acknowledge transaction.
///
/// ## Draining
/// `claimEntries()` atomically marks every unclaimed entry with a fresh claim
/// token and returns them. A second claimer — say, a Debug and an
/// /Applications copy of the app sharing the App Group — gets only entries
/// nobody holds, so the two never process the same entry. After storing (or
/// deliberately dropping) the entries, the claimer calls `acknowledge(_:)`,
/// which removes them; if it can't finish, `release(_:)` hands them back. A
/// claim that is never acknowledged or released (the app quit mid-drain)
/// expires after `claimLease`, and the entries become claimable again.
///
/// ## Format
/// JSON Lines. Each line is `{"entry": <MailIncomingMessage>, "claim": …}`
/// (`claim` absent when unclaimed). A line this build can't decode — a newer
/// entry version, or damage — is carried through every rewrite byte-for-byte
/// instead of being dropped, so an older build never destroys a newer build's
/// entries; it is never claimed by this build.
///
/// ## Concurrency
/// Every operation is one `NSFileCoordinator` claim on the file, and every
/// change is a read-modify-write inside a single coordinated write that
/// replaces the file atomically. Concurrent appends and claims from different
/// processes serialize; none loses another's change.
///
/// ## De-duplication
/// Entries are unique by `messageID` among the lines currently in the file,
/// claimed or not. Once an entry is acknowledged it is gone, and a later
/// delivery of the same message is appended again — the app's own store must
/// also de-duplicate by Message-ID.
struct MailIncomingJournal: Sendable {
    let fileURL: URL
    /// The journal keeps only the newest this-many lines, so it stays bounded
    /// if the app goes a long time without draining it.
    let maximumEntryCount: Int
    /// How long an unacknowledged claim holds its entries.
    let claimLease: TimeInterval
    /// The Darwin notification posted after each successful append, or nil
    /// to post nothing (tests). See `MailJournalChangeNotification`.
    let changeNotificationName: String?

    static let defaultMaximumEntryCount = 2_000
    static let defaultClaimLease: TimeInterval = 5 * 60

    init(
        fileURL: URL,
        maximumEntryCount: Int = defaultMaximumEntryCount,
        claimLease: TimeInterval = defaultClaimLease,
        changeNotificationName: String? = nil
    ) {
        self.fileURL = fileURL
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.claimLease = claimLease
        self.changeNotificationName = changeNotificationName
    }

    /// The journal at the shared App Group location, posting the App Group's
    /// change notification, or nil when this bundle has no usable
    /// `GuessWhoAppGroup` container.
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
    }

    /// Appends `entry` unless one with its `messageID` is already present,
    /// then posts the change notification.
    @discardableResult
    func append(_ entry: MailIncomingMessage) throws -> AppendOutcome {
        let outcome: AppendOutcome = try MailFileCoordination.write(fileURL) { url in
            var lines = try Self.lines(at: url)
            if lines.contains(where: { $0.messageID == entry.messageID }) {
                return .duplicate
            }
            lines.append(try Line(StoredLine(entry: entry, claim: nil)))
            if lines.count > maximumEntryCount {
                lines.removeFirst(lines.count - maximumEntryCount)
            }
            try Self.write(lines, to: url)
            return .appended
        }
        if outcome == .appended, let changeNotificationName {
            MailJournalChangeNotification.post(name: changeNotificationName)
        }
        return outcome
    }

    // MARK: - Draining (app)

    /// Entries held by one `claimEntries()` call.
    struct Claim: Sendable {
        let token: UUID
        /// Oldest first.
        let entries: [MailIncomingMessage]
    }

    /// Atomically claims every entry that no live claim holds. Nil when there
    /// is nothing to claim.
    func claimEntries(now: Date = Date()) throws -> Claim? {
        let token = UUID()
        return try MailFileCoordination.write(fileURL) { url in
            var lines = try Self.lines(at: url)
            var claimed: [MailIncomingMessage] = []
            for index in lines.indices {
                guard var stored = lines[index].stored else { continue }
                if let claim = stored.claim, !isExpired(claim, now: now) { continue }
                stored.claim = StoredClaim(token: token, claimedAt: now)
                lines[index] = try Line(stored)
                claimed.append(stored.entry)
            }
            guard !claimed.isEmpty else { return nil }
            try Self.write(lines, to: url)
            return Claim(token: token, entries: claimed)
        }
    }

    /// Removes every entry `claim` still holds. Call after storing the
    /// entries, or after deciding to drop them. Entries whose claim expired
    /// and was taken by another claimer are left to that claimer.
    func acknowledge(_ claim: Claim) throws {
        try rewrite { lines in
            lines.removeAll { $0.stored?.claim?.token == claim.token }
        }
    }

    /// Returns every entry `claim` still holds to the unclaimed pool, for a
    /// claimer that couldn't finish.
    func release(_ claim: Claim) throws {
        try rewrite { lines in
            for index in lines.indices {
                guard var stored = lines[index].stored,
                      stored.claim?.token == claim.token else { continue }
                stored.claim = nil
                lines[index] = try Line(stored)
            }
        }
    }

    /// A claim is live for `claimLease` either side of `now`, so a clock that
    /// jumps backwards can't pin entries for longer than one lease.
    private func isExpired(_ claim: StoredClaim, now: Date) -> Bool {
        abs(now.timeIntervalSince(claim.claimedAt)) >= claimLease
    }

    private func rewrite(_ change: (inout [Line]) throws -> Void) throws {
        try MailFileCoordination.write(fileURL) { url in
            let original = try Self.lines(at: url)
            var lines = original
            try change(&lines)
            guard lines.map(\.raw) != original.map(\.raw) else { return }
            try Self.write(lines, to: url)
        }
    }

    // MARK: - Lines

    private struct StoredClaim: Codable, Equatable {
        var token: UUID
        var claimedAt: Date
    }

    private struct StoredLine: Codable {
        var entry: MailIncomingMessage
        var claim: StoredClaim?
    }

    private struct Line {
        /// The exact bytes of the line, without its newline.
        let raw: Data
        /// Nil when this build can't decode the line.
        let stored: StoredLine?
        /// Present even for an undecodable line when it still carries a
        /// readable `messageID`, so de-duplication covers newer entries too.
        let messageID: String?

        init(_ stored: StoredLine) throws {
            self.raw = try MailIncomingJournal.encoder.encode(stored)
            self.stored = stored
            self.messageID = stored.entry.messageID
        }

        init(raw: Data, stored: StoredLine?, messageID: String?) {
            self.raw = raw
            self.stored = stored
            self.messageID = messageID
        }
    }

    /// Just enough of any line version to de-duplicate and gate on version.
    private struct Probe: Decodable {
        struct Entry: Decodable {
            let version: Int
            let messageID: String?
        }
        let entry: Entry
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func lines(at url: URL) throws -> [Line] {
        guard let data = try MailFileCoordination.contentsIfPresent(of: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { slice in
            let raw = Data(slice)
            guard raw.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\r") }) else {
                return nil
            }
            let probe = try? decoder.decode(Probe.self, from: raw)
            var stored: StoredLine?
            if let probe, probe.entry.version <= MailIncomingMessage.currentVersion {
                stored = try? decoder.decode(StoredLine.self, from: raw)
            }
            return Line(raw: raw, stored: stored, messageID: stored?.entry.messageID ?? probe?.entry.messageID)
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
