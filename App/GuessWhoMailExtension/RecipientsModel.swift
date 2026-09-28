import Foundation
import MailKit
import Observation
import os

/// One compose window's recipient list, matched against the contact cache.
///
/// `show(recipients:)` may be called on every recipient edit; each call reads
/// the cache off the main actor, and only the newest call's result is applied.
@MainActor
@Observable
final class RecipientsModel {

    enum Status: Equatable {
        /// The first lookup hasn't finished.
        case loading
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
        /// Nil for a recipient the cache doesn't know.
        let summary: MailContactSummary?
    }

    private(set) var status: Status = .loading
    private(set) var rows: [Row] = []

    @ObservationIgnored private let contactCache: MailContactCacheStore?
    @ObservationIgnored private var generation = 0

    init(contactCache: MailContactCacheStore?) {
        self.contactCache = contactCache
    }

    func show(recipients addresses: [MEEmailAddress]) {
        let recipients = Self.uniqueRecipients(addresses)
        generation += 1
        let generation = self.generation
        let contactCache = self.contactCache
        Task {
            let lookup = await Task.detached(priority: .userInitiated) {
                Self.lookUp(recipients, in: contactCache)
            }.value
            guard generation == self.generation else { return }
            rows = lookup.rows
            status = lookup.status
        }
    }

    // MARK: - Lookup (off the main actor)

    private struct Recipient: Sendable {
        let address: String
        let normalized: String?
    }

    /// Recipients in window order, each address once even when it appears in
    /// both To and Cc.
    private static func uniqueRecipients(_ addresses: [MEEmailAddress]) -> [Recipient] {
        var seen = Set<String>()
        var recipients: [Recipient] = []
        for address in addresses {
            let normalized = address.addressString.flatMap(MailAddressNormalizer.normalize)
                ?? MailAddressNormalizer.normalize(address.rawString)
            let display = normalized ?? address.rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty, seen.insert(display).inserted else { continue }
            recipients.append(Recipient(address: display, normalized: normalized))
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
        for recipient in recipients {
            let summaries = recipient.normalized.map { snapshot?.summaries(forAddress: $0) ?? [] } ?? []
            if summaries.isEmpty {
                rows.append(Row(id: recipient.address, address: recipient.address, summary: nil))
            }
            for (index, summary) in summaries.enumerated() {
                rows.append(Row(id: "\(recipient.address)#\(index)", address: recipient.address, summary: summary))
            }
        }
        return (rows, snapshot == nil ? .contactsUnavailable : .ready)
    }
}
