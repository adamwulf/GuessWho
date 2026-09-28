#if targetEnvironment(macCatalyst)

import Foundation
import UIKit
import GuessWhoLogging
import GuessWhoSync

/// App-side coordinator for the Apple Mail extension handoff.
///
/// One process-wide instance publishes the contact cache Mail reads and drains
/// Mail's incoming-message journal into the live `ContactsRepository`. It is
/// owned by `GuessWhoAppDelegate`, not a scene, because Catalyst may open more
/// than one window while the App Group files still have one writer/drainer.
@MainActor
final class MailBridgeController {
    private static let log = GuessWhoLog.logger("app.mail-bridge")
    private static let debounceNanoseconds: UInt64 = 300_000_000
    private static let renewalStride = 10

    private let service: SyncService
    private let repository: ContactsRepository
    private let notificationCenter: NotificationCenter
    private let cacheStore: MailContactCacheStore?
    private let journal: MailIncomingJournal?
    private let journalNotificationName: String?

    private var notificationTokens: [NSObjectProtocol] = []
    private var journalObserver: MailJournalChangeNotification.Observer?
    private var startupTask: Task<Void, Never>?
    private var publishDebounceTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var publishPending = false
    private var drainPending = false
    private var isShuttingDown = false

    /// Thumbnail reads are comparatively expensive. The cache is valid for one
    /// contact-data revision; membership/favorite-only changes reuse it.
    private var photoRevision: Int?
    private var loadedPhotoIDs: Set<ContactID> = []
    private var photosByContactID: [ContactID: Data] = [:]

    init(
        service: SyncService,
        repository: ContactsRepository,
        notificationCenter: NotificationCenter = .default,
        cacheStore: MailContactCacheStore? = MailContactCacheStore.shared(),
        journal: MailIncomingJournal? = MailIncomingJournal.shared(),
        journalNotificationName: String? = MailJournalChangeNotification.name()
    ) {
        self.service = service
        self.repository = repository
        self.notificationCenter = notificationCenter
        self.cacheStore = cacheStore
        self.journal = journal
        self.journalNotificationName = journalNotificationName
    }

    func bootstrap() {
        guard startupTask == nil, !isShuttingDown else { return }
        installObservers()
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await repository.waitUntilInitialLoadCompletes()
            guard !Task.isCancelled, !isShuttingDown else { return }

            // Group favorites resolve through the adoption cache populated by
            // this read. It is safe if the sidebar races the same idempotent
            // load; revision checks below reject an in-between snapshot.
            await repository.loadGroups()
            guard !Task.isCancelled, !isShuttingDown else { return }
            requestPublish()
            requestDrain()
        }
    }

    func shutdown() {
        isShuttingDown = true
        startupTask?.cancel()
        publishDebounceTask?.cancel()
        publishTask?.cancel()
        drainTask?.cancel()
        startupTask = nil
        publishDebounceTask = nil
        publishTask = nil
        drainTask = nil
        journalObserver = nil
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    // MARK: - Observation

    private func installObservers() {
        notificationTokens.append(notificationCenter.addObserver(
            forName: .contactsRepositoryDidReload,
            object: repository,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePublish() }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: .contactsRepositoryGroupMembershipDidChange,
            object: repository,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePublish() }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePublish() }
        })
        notificationTokens.append(notificationCenter.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedulePublish()
                self?.requestDrain()
            }
        })

        if let journalNotificationName {
            journalObserver = MailJournalChangeNotification.Observer(name: journalNotificationName) {
                [weak self] in
                Task { @MainActor [weak self] in self?.requestDrain() }
            }
        }
    }

    private func schedulePublish() {
        guard !isShuttingDown else { return }
        publishDebounceTask?.cancel()
        publishDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            } catch {
                return
            }
            self?.requestPublish()
        }
    }

    private func requestPublish() {
        guard !isShuttingDown else { return }
        if publishTask != nil {
            publishPending = true
            return
        }
        publishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                publishPending = false
                await publishContactSnapshot()
            } while publishPending && !Task.isCancelled && !isShuttingDown
            publishTask = nil
        }
    }

    private func requestDrain() {
        guard !isShuttingDown else { return }
        if drainTask != nil {
            drainPending = true
            return
        }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                drainPending = false
                await drainMailJournal()
            } while drainPending && !Task.isCancelled && !isShuttingDown
            drainTask = nil
        }
    }

    // MARK: - Contact cache publication

    private enum SnapshotBuildResult {
        case ready(MailContactSnapshot)
        case retry
        case preserveExisting
    }

    private func publishContactSnapshot() async {
        guard repository.hasCompletedInitialLoad,
              case .published = repository.lastReloadOutcome,
              let cacheStore
        else { return }

        let result = await buildContactSnapshot()
        switch result {
        case .retry:
            publishPending = true
            return
        case .preserveExisting:
            return
        case .ready(var candidate):
            do {
                let existing = try await Task.detached(priority: .utility) {
                    try cacheStore.read()
                }.value
                switch existing {
                case .current(let current):
                    // Keep the old timestamp for the equality check so a
                    // sidecar echo or activation does not rewrite the file.
                    candidate.generatedAt = current.generatedAt
                    guard candidate != current else { return }
                case .newerFormat(let version, _):
                    // Never downgrade a cache written by a newer app. The
                    // matching newer Mail extension can keep using it.
                    Self.log.notice("mail contact cache is from a newer app; preserving it", [
                        "version": "\(version)"
                    ])
                    return
                case nil:
                    break
                }
                candidate.generatedAt = Date()
                let snapshotToWrite = candidate
                try await Task.detached(priority: .utility) {
                    try cacheStore.write(snapshotToWrite)
                }.value
            } catch {
                // A corrupt/current-version cache is recoverable: writing the
                // newly built snapshot replaces it. An I/O failure will fail
                // again here and a later trigger retries.
                do {
                    candidate.generatedAt = Date()
                    let snapshotToWrite = candidate
                    try await Task.detached(priority: .utility) {
                        try cacheStore.write(snapshotToWrite)
                    }.value
                } catch {
                    Self.log.error("mail contact cache publish failed", [
                        "errorType": String(reflecting: type(of: error))
                    ])
                }
            }
        }
    }

    private func buildContactSnapshot() async -> SnapshotBuildResult {
        let contactRevision = repository.contactDataRevision
        let favorites: [Favorite]
        do {
            favorites = try service.loadFavorites()
        } catch {
            // A failed favorites read must never masquerade as no favorites
            // and erase Mail's highlight reasons.
            Self.log.error("mail contact cache favorites read failed", [
                "errorType": String(reflecting: type(of: error))
            ])
            return .preserveExisting
        }

        var reasonsByContactID: [ContactID: Set<MailHighlightReason>] = [:]
        let favoriteItems = repository.favoriteListItems(from: favorites, event: { _ in nil })
        for item in favoriteItems {
            switch item.kind {
            case .contact:
                guard let contact = item.contact else { continue }
                reasonsByContactID[contact.contactID, default: []].insert(.favoriteContact)
                if contact.contactType == .organization {
                    for member in repository.contactsAssociated(with: contact) {
                        reasonsByContactID[member.contactID, default: []]
                            .insert(.favoriteOrganizationMember)
                    }
                }
            case .group:
                guard let group = item.group else { continue }
                let snapshot = await repository.memberSnapshot(for: .group(group))
                guard snapshot.failedGroups.isEmpty else {
                    // A failed group read is unknown membership, not an empty
                    // group. Keep Mail's last complete cache.
                    return .preserveExisting
                }
                guard repository.isCurrent(snapshot) else { return .retry }
                for member in snapshot.contacts {
                    reasonsByContactID[member.contactID, default: []].insert(.favoriteGroupMember)
                }
            case .department:
                guard let department = item.department else { continue }
                for member in repository.contactsAssociated(
                    with: department.organization,
                    inDepartment: department.department
                ) {
                    reasonsByContactID[member.contactID, default: []]
                        .insert(.favoriteOrganizationMember)
                }
            case .event, .guide, .place:
                continue
            }
        }

        guard repository.contactDataRevision == contactRevision else { return .retry }
        if photoRevision != contactRevision {
            photoRevision = contactRevision
            loadedPhotoIDs.removeAll()
            photosByContactID.removeAll()
        }

        var candidates: [MailSnapshotContact] = []
        candidates.reserveCapacity(repository.contacts.count)
        for contact in repository.contacts {
            let id = contact.contactID
            var thumbnail: Data?
            if contact.imageDataAvailable {
                if loadedPhotoIDs.contains(id) {
                    thumbnail = photosByContactID[id]
                } else {
                    thumbnail = try? await repository.contactPhotoData(for: id, kind: .thumbnail)?.data
                    loadedPhotoIDs.insert(id)
                    if let thumbnail { photosByContactID[id] = thumbnail }
                }
            }
            candidates.append(MailSnapshotContact(
                contact: contact,
                thumbnail: thumbnail,
                highlightReasons: reasonsByContactID[id] ?? []
            ))
        }
        guard repository.contactDataRevision == contactRevision else { return .retry }
        return .ready(MailContactSnapshotBuilder.build(candidates, generatedAt: .distantPast))
    }

    // MARK: - Incoming journal drain

    private func drainMailJournal() async {
        guard repository.hasCompletedInitialLoad,
              case .published = repository.lastReloadOutcome,
              let journal
        else { return }

        while !Task.isCancelled, !isShuttingDown {
            let claim: MailIncomingJournal.Claim?
            do {
                claim = try await Task.detached(priority: .utility) {
                    try journal.claimEntries()
                }.value
            } catch {
                Self.log.error("mail journal claim failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
                return
            }
            guard let claim else { return }
            let mayContinue = await drain(claim, from: journal)
            guard mayContinue else { return }
        }
    }

    /// Returns false when at least one entry was released for retry, preventing
    /// this drain pass from immediately reclaiming the same poison entry.
    private func drain(
        _ claim: MailIncomingJournal.Claim,
        from journal: MailIncomingJournal
    ) async -> Bool {
        var owned = Set(claim.entries.map(\.messageID))
        var acknowledge = Set<String>()
        var retry = Set<String>()

        for (index, entry) in claim.entries.enumerated() {
            if index.isMultiple(of: Self.renewalStride) {
                do {
                    let outcome = try await Task.detached(priority: .utility) {
                        try journal.renew(claim)
                    }.value
                    owned = outcome.applied
                    if outcome.lostOwnership {
                        Self.log.notice("mail journal claim ownership changed", [
                            "lostCount": "\(outcome.lost.count)"
                        ])
                    }
                } catch {
                    Self.log.error("mail journal claim renewal failed", [
                        "errorType": String(reflecting: type(of: error))
                    ])
                    return false
                }
            }
            guard owned.contains(entry.messageID) else { continue }

            guard case .published = repository.lastReloadOutcome else {
                retry.insert(entry.messageID)
                continue
            }
            guard let activity = MailActivity(
                senderAddress: entry.sender,
                subject: entry.subject,
                receivedAt: entry.receivedAt,
                messageID: entry.messageID,
                mailURL: entry.messageURL?.absoluteString
            ) else {
                acknowledge.insert(entry.messageID)
                continue
            }

            var seen = Set<ContactID>()
            let contactIDs = repository.contactIDs(matchingEmail: entry.sender).filter {
                seen.insert($0).inserted
            }
            guard !contactIDs.isEmpty else {
                // The sender was known when Mail appended the entry but no
                // longer matches after the app loaded. This cannot become
                // actionable without a new message/cache publication.
                acknowledge.insert(entry.messageID)
                continue
            }

            do {
                // Sequential awaits per contact are required by the repository
                // identity contract: the first write may mint the identity and
                // every later write must observe that mint.
                for contactID in contactIDs {
                    try await repository.recordMailActivity(activity, for: contactID)
                }
                acknowledge.insert(entry.messageID)
            } catch {
                retry.insert(entry.messageID)
                Self.log.error("mail activity record failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
            }
        }

        // Never settle an entry whose ownership was lost during a renewal.
        acknowledge.formIntersection(owned)
        retry.formIntersection(owned)
        if !acknowledge.isEmpty {
            do {
                let messageIDs = acknowledge
                _ = try await Task.detached(priority: .utility) {
                    try journal.acknowledge(claim, messageIDs: messageIDs)
                }.value
            } catch {
                Self.log.error("mail journal acknowledge failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
                return false
            }
        }
        if !retry.isEmpty {
            do {
                let messageIDs = retry
                _ = try await Task.detached(priority: .utility) {
                    try journal.release(claim, messageIDs: messageIDs)
                }.value
            } catch {
                Self.log.error("mail journal release failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
            }
            return false
        }
        return true
    }
}

/// Pure input to the cache projection. Keeping the projection independent of
/// repository I/O makes its address/reason/compose-field behavior testable.
struct MailSnapshotContact {
    let contact: Contact
    let thumbnail: Data?
    let highlightReasons: Set<MailHighlightReason>
}

enum MailContactSnapshotBuilder {
    static func build(
        _ contacts: [MailSnapshotContact],
        generatedAt: Date
    ) -> MailContactSnapshot {
        var snapshot = MailContactSnapshot(generatedAt: generatedAt)
        let ordered = contacts.sorted { lhs, rhs in
            sortKey(lhs) < sortKey(rhs)
        }
        for candidate in ordered {
            let addresses = candidate.contact.emailAddresses.map(\.value)
            guard !addresses.isEmpty else { continue }
            let fallbackName = addresses.compactMap(MailAddressNormalizer.normalize).first ?? "Unknown contact"
            let summary = MailContactSummary(
                displayName: nonempty(candidate.contact.displayName) ?? fallbackName,
                organization: nonempty(candidate.contact.organizationName),
                jobTitle: nonempty(candidate.contact.jobTitle),
                thumbnail: candidate.thumbnail,
                highlightReasons: candidate.highlightReasons
            )
            snapshot.add(summary, forAddresses: addresses)
        }
        return snapshot
    }

    private static func sortKey(_ candidate: MailSnapshotContact) -> String {
        let addresses = candidate.contact.emailAddresses
            .compactMap { MailAddressNormalizer.normalize($0.value) }
            .sorted()
            .joined(separator: "\u{1f}")
        return [
            addresses,
            candidate.contact.displayName,
            candidate.contact.organizationName,
            candidate.contact.jobTitle,
            candidate.thumbnail?.base64EncodedString() ?? "",
            candidate.highlightReasons.map(\.rawValue).sorted().joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
