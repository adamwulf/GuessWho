import Foundation
import MailKit
import Observation
import os

/// One compose window's recipient list, matched against the contact cache.
///
/// `showNow(_:)` looks the recipients up synchronously, for the popover's
/// first layout. `show(_:)` may be called on every recipient edit; each call
/// reads the cache off the main actor, and only the newest call's result is
/// applied.
@MainActor
@Observable
final class RecipientsModel {

    enum Status: Equatable {
        case ready
        /// The cache couldn't be read, hasn't been published yet, or is in a
        /// newer format; every row shows only its address.
        case contactsUnavailable
    }

    struct Row: Identifiable, Equatable {
        let id: String
        /// What Mail shows for the recipient: the bare address when valid,
        /// otherwise the raw token text.
        let address: String
        /// The name Mail gave with the address, when it gave one.
        let displayName: String?
        /// The normalized address, for adding the recipient as a new
        /// contact; nil when the token is not a valid address.
        let normalizedAddress: String?
        /// Nil for a recipient the cache doesn't know.
        let summary: MailContactSummary?
    }

    /// One recipient token from the compose window, reduced to plain values
    /// so it can cross from MailKit's XPC queue to the main actor.
    struct Recipient: Sendable {
        let address: String
        let normalized: String?
        /// From the token's raw text (`"Jane Doe" <jane@example.com>`).
        /// Whether Mail's compose session includes a name there is
        /// unverified, so this is often nil.
        let displayName: String?
    }

    private(set) var status: Status = .ready
    private(set) var rows: [Row] = []

    @ObservationIgnored private let contactCache: MailContactCacheStore?
    @ObservationIgnored private var generation = 0

    init(contactCache: MailContactCacheStore?) {
        self.contactCache = contactCache
    }

    /// Looks the recipients up on the calling (main) thread. Mail sizes the
    /// popover from the view's preferred size when it first lays it out, so
    /// the rows must be in place before the view controller is returned. The
    /// cache store memoizes the decoded file (warmed when the compose window
    /// opens), so this is usually just a coordinated file stat.
    func showNow(_ recipients: [Recipient]) {
        generation += 1
        apply(Self.lookUp(recipients, in: contactCache))
    }

    func show(_ recipients: [Recipient]) {
        generation += 1
        let generation = self.generation
        let contactCache = self.contactCache
        Task {
            let lookup = await Task.detached(priority: .userInitiated) {
                Self.lookUp(recipients, in: contactCache)
            }.value
            guard generation == self.generation else { return }
            apply(lookup)
        }
    }

    private func apply(_ lookup: (rows: [Row], status: Status)) {
        rows = lookup.rows
        status = lookup.status
    }

    // MARK: - Lookup (any thread)

    /// Recipients in window order, each address once even when it appears in
    /// both To and Cc.
    nonisolated static func recipients(from addresses: [MEEmailAddress]) -> [Recipient] {
        var seen = Set<String>()
        var recipients: [Recipient] = []
        for address in addresses {
            let normalized = address.addressString.flatMap(MailAddressNormalizer.normalize)
                ?? MailAddressNormalizer.normalize(address.rawString)
            let display = normalized ?? address.rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty, seen.insert(display).inserted else { continue }
            recipients.append(Recipient(
                address: display,
                normalized: normalized,
                displayName: MailAddressNormalizer.displayName(address.rawString)
            ))
        }
        return recipients
    }

    private nonisolated static func lookUp(
        _ recipients: [Recipient], in contactCache: MailContactCacheStore?
    ) -> (rows: [Row], status: Status) {
        let contents: MailContactCacheContents?
        do {
            contents = try contactCache?.read()
        } catch {
            Logger.mailExtension("compose").error(
                "contact cache read failed: \(LoggedError.fingerprint(error), privacy: .public)")
            contents = nil
        }
        // Only a fully readable snapshot has details to show; a newer-format
        // cache knows addresses but not people.
        let snapshot: MailContactSnapshot?
        if case .current(let current) = contents {
            snapshot = current
        } else {
            snapshot = nil
        }

        var rows: [Row] = []
        // One person can be in the window under several of their addresses;
        // they get one row, at their first address.
        var seenContactIDs = Set<String>()
        for recipient in recipients {
            let summaries = recipient.normalized.map { snapshot?.summaries(forAddress: $0) ?? [] } ?? []
            if summaries.isEmpty {
                rows.append(row(id: recipient.address, recipient: recipient, summary: nil))
            }
            for (index, summary) in summaries.enumerated() {
                if let contactID = summary.contactID, !seenContactIDs.insert(contactID).inserted {
                    continue
                }
                rows.append(row(id: "\(recipient.address)#\(index)", recipient: recipient, summary: summary))
            }
        }
        return (rows, snapshot == nil ? .contactsUnavailable : .ready)
    }

    private nonisolated static func row(id: String, recipient: Recipient, summary: MailContactSummary?) -> Row {
        Row(
            id: id,
            address: recipient.address,
            displayName: recipient.displayName,
            normalizedAddress: recipient.normalized,
            summary: summary
        )
    }
}
