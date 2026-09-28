#if targetEnvironment(macCatalyst)

import Foundation
import CryptoKit
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
    private static let retryNanoseconds: UInt64 = 2_000_000_000
    private static let publishRecoveryRetryNanoseconds: UInt64 = 30_000_000_000
    private static let drainRetryNanoseconds: UInt64 = 300_000_000_000
    private static let renewalStride = 10
    private static let maximumDrainBatchesPerPass = 10

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
    private var drainRetryTask: Task<Void, Never>?
    private var groupRecoveryTask: Task<Void, Never>?
    private var publishPending = false
    private var drainPending = false
    private var isShuttingDown = false
    private var activeClaims: [UUID: MailIncomingJournal.Claim] = [:]
    /// Contact-data revision known to be represented by a successfully written
    /// or byte-equivalent current cache. Nil while publication is pending or a
    /// newer-format cache is intentionally preserved.
    private var publishedContactRevision: Int?

    /// Thumbnail reads are comparatively expensive. Membership/favorite-only
    /// changes reuse every entry. A contact-data reload clears the cache unless
    /// it is the exact private-identity mint emitted by mail activity storage.
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
        drainRetryTask?.cancel()
        groupRecoveryTask?.cancel()
        let claims = Array(activeClaims.values)
        activeClaims.removeAll()
        if let journal, !claims.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                for claim in claims {
                    _ = try? journal.release(claim)
                }
            }
        }
        startupTask = nil
        publishDebounceTask = nil
        publishTask = nil
        drainTask = nil
        drainRetryTask = nil
        groupRecoveryTask = nil
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
        ) { [weak self] notification in
            let mailContactProjectionChanged = notification.userInfo?[
                ContactsRepositoryDidReloadKey.mailContactProjectionChanged
            ] as? Bool ?? true
            let mailActivityIdentityMinted = notification.userInfo?[
                ContactsRepositoryDidReloadKey.mailActivityIdentityMinted
            ] as? Bool ?? false
            let previousRevision = notification.userInfo?[
                ContactsRepositoryDidReloadKey.mailActivityIdentityMintedFromContactRevision
            ] as? Int
            MainActor.assumeIsolated {
                guard let self else { return }
                self.photoRevision = MailThumbnailCachePolicy.revisionAfterReload(
                    cachedRevision: self.photoRevision,
                    identityMinted: mailActivityIdentityMinted,
                    mintedFromRevision: previousRevision,
                    currentRevision: self.repository.contactDataRevision
                )
                if mailActivityIdentityMinted,
                   let previousRevision,
                   self.publishedContactRevision == previousRevision {
                    // Addresses and compose fields are unchanged by the
                    // private identity URL. Carry the publication marker only
                    // from the exact revision the mint replaced.
                    self.publishedContactRevision = self.repository.contactDataRevision
                } else if mailContactProjectionChanged {
                    self.publishedContactRevision = nil
                    self.schedulePublish()
                }
                self.recoverGroupsIfNeeded()
                if mailContactProjectionChanged { self.requestDrain() }
            }
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
                self?.publishedContactRevision = nil
                self?.schedulePublish()
                self?.recoverGroupsIfNeeded()
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

    private func schedulePublishRetry() {
        guard !isShuttingDown else { return }
        publishDebounceTask?.cancel()
        publishDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.retryNanoseconds)
            } catch {
                return
            }
            self?.requestPublish()
        }
    }

    private func schedulePublishRecoveryRetry() {
        guard !isShuttingDown else { return }
        publishDebounceTask?.cancel()
        publishDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.publishRecoveryRetryNanoseconds)
            } catch {
                return
            }
            self?.requestPublish()
        }
    }

    private func recoverGroupsIfNeeded() {
        guard !repository.hasAuthoritativeGroupCache,
              !repository.isLoadingGroups,
              groupRecoveryTask == nil,
              !isShuttingDown
        else { return }
        groupRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await repository.loadGroups()
            groupRecoveryTask = nil
            guard !Task.isCancelled, !isShuttingDown else { return }
            if repository.hasAuthoritativeGroupCache { schedulePublish() }
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

    private func scheduleDrainRetry() {
        guard drainRetryTask == nil, !isShuttingDown else { return }
        drainRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.drainRetryNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            drainRetryTask = nil
            requestDrain()
        }
    }

    // MARK: - Contact cache publication

    private enum SnapshotBuildResult {
        case ready(MailContactSnapshot, contactRevision: Int)
        case retry
        case preserveExisting
    }

    private func publishContactSnapshot() async {
        guard repository.hasCompletedInitialLoad,
              !repository.isLoading,
              case .published = repository.lastReloadOutcome,
              let cacheStore
        else { return }

        let result = await buildContactSnapshot()
        switch result {
        case .retry:
            schedulePublishRetry()
            return
        case .preserveExisting:
            recoverGroupsIfNeeded()
            schedulePublishRecoveryRetry()
            return
        case .ready(let candidate, let contactRevision):
            switch await MailContactCachePublication.publish(candidate, to: cacheStore) {
            case .written, .unchanged:
                if !repository.isLoading,
                   case .published = repository.lastReloadOutcome,
                   repository.contactDataRevision == contactRevision {
                    publishedContactRevision = contactRevision
                    // A drain may have deferred an unmatched sender while
                    // waiting for this exact publication proof.
                    requestDrain()
                }
            case .preservedNewer(let version):
                Self.log.notice("mail contact cache is from a newer app; preserving it", [
                    "version": "\(version)"
                ])
            case .failed(let errorType):
                Self.log.error("mail contact cache publish failed", [
                    "errorType": errorType
                ])
                schedulePublishRecoveryRetry()
            }
        }
    }

    private func buildContactSnapshot() async -> SnapshotBuildResult {
        guard !repository.isLoading,
              case .published = repository.lastReloadOutcome
        else { return .preserveExisting }
        let contactRevision = repository.contactDataRevision
        let memberRevisions = repository.memberRevisions
        let favorites: [Favorite]
        do {
            favorites = try await service.loadFavoritesOffMain()
        } catch {
            // A failed favorites read must never masquerade as no favorites
            // and erase Mail's highlight reasons.
            Self.log.error("mail contact cache favorites read failed", [
                "errorType": String(reflecting: type(of: error))
            ])
            return .preserveExisting
        }

        // `loadGroups()` preserves its last good cache on failure. Publishing
        // from that cache would silently drop a newly favorited group whose
        // identity could not be resolved during the failed load, so a group
        // favorite plus any group error is an incomplete projection.
        if favorites.contains(where: { $0.kind == .group }),
           !repository.hasAuthoritativeGroupCache {
            return .preserveExisting
        }

        var reasonsByContactID: [ContactID: Set<MailHighlightReason>] = [:]
        for favorite in favorites {
            switch favorite.kind {
            case .contact:
                guard let contact = repository.contact(guessWhoID: favorite.id) else { continue }
                reasonsByContactID[contact.contactID, default: []].insert(.favoriteContact)
                if contact.contactType == .organization {
                    for member in repository.contactsAssociated(with: contact) {
                        reasonsByContactID[member.contactID, default: []]
                            .insert(.favoriteOrganizationMember)
                    }
                }
            case .group:
                guard let group = repository.cachedGroup(forFavoriteID: favorite.id) else { continue }
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
                guard let key = DepartmentFavoriteKey(favoriteID: favorite.id),
                      let organization = repository.contact(
                        guessWhoID: key.organizationGuessWhoID
                      )
                else { continue }
                for member in repository.contactsAssociated(
                    with: organization,
                    inDepartment: key.department
                ) {
                    reasonsByContactID[member.contactID, default: []]
                        .insert(.favoriteOrganizationMember)
                }
            case .event, .guide, .place:
                continue
            }
        }

        guard !repository.isLoading,
              case .published = repository.lastReloadOutcome,
              repository.contactDataRevision == contactRevision,
              repository.memberRevisions == memberRevisions
        else { return .retry }
        if photoRevision != contactRevision {
            photoRevision = contactRevision
            loadedPhotoIDs.removeAll()
            photosByContactID.removeAll()
        }

        var candidates: [MailSnapshotContact] = []
        candidates.reserveCapacity(repository.contacts.count)
        for contact in repository.contacts {
            guard !Task.isCancelled,
                  !repository.isLoading,
                  repository.contactDataRevision == contactRevision,
                  repository.memberRevisions == memberRevisions
            else { return .retry }
            guard contact.emailAddresses.contains(where: {
                MailAddressNormalizer.normalize($0.value) != nil
            }) else { continue }
            let id = contact.contactID
            var thumbnail: Data?
            if loadedPhotoIDs.contains(id) {
                thumbnail = photosByContactID[id]
            } else {
                // Do not gate this read on `imageDataAvailable`: the Contacts
                // adapter documents that flag as a hint, never a veto, because
                // thumbnail-only cards can report false. Each id is read at
                // most once per contact-data revision and the repository moves
                // the actual Contacts fetch off the main actor.
                do {
                    thumbnail = try await repository.contactPhotoData(for: id, kind: .thumbnail)?.data
                    guard !Task.isCancelled,
                          !repository.isLoading,
                          repository.contactDataRevision == contactRevision,
                          repository.memberRevisions == memberRevisions
                    else { return .retry }
                    loadedPhotoIDs.insert(id)
                    if let thumbnail { photosByContactID[id] = thumbnail }
                } catch {
                    // The Contacts flag is only a hint and transient reads can
                    // fail. Keep a previously cached photo and retry this ID
                    // on the next publication instead of publishing a false
                    // permanent "no photo" result for the whole revision.
                    thumbnail = photosByContactID[id]
                }
            }
            candidates.append(MailSnapshotContact(
                contact: contact,
                thumbnail: thumbnail,
                highlightReasons: reasonsByContactID[id] ?? []
            ))
        }
        guard !repository.isLoading,
              case .published = repository.lastReloadOutcome,
              repository.contactDataRevision == contactRevision,
              repository.memberRevisions == memberRevisions
        else { return .retry }
        let snapshot = await Task.detached(priority: .utility) {
            MailContactSnapshotBuilder.build(candidates, generatedAt: .distantPast)
        }.value
        guard !repository.isLoading,
              case .published = repository.lastReloadOutcome,
              repository.contactDataRevision == contactRevision,
              repository.memberRevisions == memberRevisions
        else { return .retry }
        return .ready(snapshot, contactRevision: contactRevision)
    }

    // MARK: - Incoming journal drain

    private func drainMailJournal() async {
        guard repository.hasCompletedInitialLoad,
              !repository.isLoading,
              case .published = repository.lastReloadOutcome,
              let journal
        else { return }

        await releaseOutstandingClaims(from: journal)
        guard activeClaims.isEmpty else {
            scheduleDrainRetry()
            return
        }

        var addressIndex: (revision: Int, value: MailContactAddressIndex)?
        var deferred: [DeferredClaim] = []
        var batchCount = 0
        var stopAfterCurrentBatch = false
        while !Task.isCancelled,
              !isShuttingDown,
              !repository.isLoading,
              case .published = repository.lastReloadOutcome,
              batchCount < Self.maximumDrainBatchesPerPass {
            let claim: MailIncomingJournal.Claim?
            do {
                claim = try await MailBridgeBlockingIO.run {
                    try journal.claimEntries()
                }
            } catch {
                Self.log.error("mail journal claim failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
                scheduleDrainRetry()
                break
            }
            guard let claim else { break }
            batchCount += 1
            activeClaims[claim.token] = claim
            let currentRevision = repository.contactDataRevision
            let index: MailContactAddressIndex
            if let addressIndex, addressIndex.revision == currentRevision {
                index = addressIndex.value
            } else {
                index = MailContactAddressIndex(contacts: repository.contacts)
                addressIndex = (currentRevision, index)
            }
            switch await drain(
                claim,
                from: journal,
                addressIndex: index,
                addressIndexRevision: currentRevision
            ) {
            case .settled:
                activeClaims.removeValue(forKey: claim.token)
            case .deferred(let messageIDs):
                deferred.append(DeferredClaim(claim: claim, messageIDs: messageIDs))
            }

            // Keep poison entries out of the unclaimed pool while later
            // batches drain, but extend their leases so a long pass cannot
            // reclaim its own deferred work.
            var renewed: [DeferredClaim] = []
            for item in deferred {
                do {
                    let claim = item.claim
                    let messageIDs = item.messageIDs
                    let outcome = try await MailBridgeBlockingIO.run {
                        try journal.renew(claim, messageIDs: messageIDs)
                    }
                    if !outcome.applied.isEmpty {
                        renewed.append(DeferredClaim(
                            claim: claim,
                            messageIDs: outcome.applied
                        ))
                    } else {
                        activeClaims.removeValue(forKey: claim.token)
                    }
                } catch {
                    renewed.append(item)
                    stopAfterCurrentBatch = true
                    Self.log.error("mail journal deferred renewal failed", [
                        "errorType": String(reflecting: type(of: error))
                    ])
                }
            }
            deferred = renewed
            if stopAfterCurrentBatch { break }
        }

        var needsRetry = !deferred.isEmpty
        for item in deferred {
            do {
                let claim = item.claim
                let messageIDs = item.messageIDs
                _ = try await MailBridgeBlockingIO.run {
                    try journal.release(claim, messageIDs: messageIDs)
                }
                activeClaims.removeValue(forKey: claim.token)
            } catch {
                needsRetry = true
                Self.log.error("mail journal deferred release failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
            }
        }
        if needsRetry || batchCount == Self.maximumDrainBatchesPerPass {
            scheduleDrainRetry()
        }
    }

    private struct DeferredClaim {
        let claim: MailIncomingJournal.Claim
        let messageIDs: Set<String>
    }

    /// Retry releases that previously failed before claiming new work. A live
    /// five-minute lease is otherwise invisible to `claimEntries`, so merely
    /// waking again before the lease expires would observe an empty journal.
    private func releaseOutstandingClaims(from journal: MailIncomingJournal) async {
        for claim in Array(activeClaims.values) {
            do {
                _ = try await MailBridgeBlockingIO.run {
                    try journal.release(claim)
                }
                activeClaims.removeValue(forKey: claim.token)
            } catch {
                Self.log.error("mail journal outstanding release failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
            }
        }
    }

    private enum ClaimDrainResult {
        case settled
        case deferred(Set<String>)
    }

    /// Failed entries remain claimed until the pass has drained later batches.
    /// That prevents one poison message from being immediately reclaimed at
    /// the head of the journal and throttling the rest of the backlog.
    private func drain(
        _ claim: MailIncomingJournal.Claim,
        from journal: MailIncomingJournal,
        addressIndex initialAddressIndex: MailContactAddressIndex,
        addressIndexRevision initialAddressIndexRevision: Int
    ) async -> ClaimDrainResult {
        var owned = Set(claim.entries.map(\.messageID))
        var acknowledge = Set<String>()
        var retry = Set<String>()
        var addressIndex = initialAddressIndex
        var addressIndexRevision = initialAddressIndexRevision

        for (index, entry) in claim.entries.enumerated() {
            guard !Task.isCancelled, !isShuttingDown else {
                retry.formUnion(owned)
                break
            }
            if index.isMultiple(of: Self.renewalStride) {
                do {
                    let outcome = try await MailBridgeBlockingIO.run {
                        try journal.renew(claim)
                    }
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
                    return .deferred(owned)
                }
            }
            guard owned.contains(entry.messageID) else { continue }

            guard !repository.isLoading,
                  case .published = repository.lastReloadOutcome
            else {
                retry.insert(entry.messageID)
                continue
            }
            let safeMailURL = MailMessageID.mailDeepLink(for: entry.messageID)?.absoluteString
            guard let activity = MailActivity(
                senderAddress: entry.sender,
                subject: entry.subject,
                receivedAt: entry.receivedAt,
                messageID: entry.messageID,
                mailURL: safeMailURL
            ) else {
                acknowledge.insert(entry.messageID)
                continue
            }

            if addressIndexRevision != repository.contactDataRevision {
                addressIndexRevision = repository.contactDataRevision
                addressIndex = MailContactAddressIndex(contacts: repository.contacts)
            }
            let contactIDs = addressIndex.contactIDs(matching: entry.sender)
            guard !contactIDs.isEmpty else {
                if MailJournalDrainPolicy.shouldAcknowledgeUnmatched(
                    publishedContactRevision: publishedContactRevision,
                    currentContactRevision: repository.contactDataRevision,
                    receivedAt: entry.receivedAt
                ) {
                    // The extension saw the sender in an older cache, while a
                    // successful publication proves the current cache and
                    // repository now agree that the address is gone.
                    acknowledge.insert(entry.messageID)
                } else {
                    // Publication is pending or a newer-format cache is being
                    // preserved. Keep the message until absence is proven.
                    retry.insert(entry.messageID)
                    schedulePublish()
                }
                continue
            }

            do {
                // Sequential awaits per contact are required by the repository
                // identity contract: the first write may mint the identity and
                // every later write must observe that mint.
                for contactID in contactIDs {
                    guard !repository.isLoading,
                          case .published = repository.lastReloadOutcome
                    else { throw MailBridgeRepositoryUnavailableError() }
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
                _ = try await MailBridgeBlockingIO.run {
                    try journal.acknowledge(claim, messageIDs: messageIDs)
                }
            } catch {
                Self.log.error("mail journal acknowledge failed", [
                    "errorType": String(reflecting: type(of: error))
                ])
                return .deferred(owned)
            }
        }
        return retry.isEmpty ? .settled : .deferred(retry)
    }
}

private struct MailBridgeRepositoryUnavailableError: Error {}

/// `NSFileCoordinator` is synchronous and can block while another process
/// holds the App Group file presenter. Keep those operations off Swift's
/// cooperative executor just as the repository does for coordinated reads.
private enum MailBridgeBlockingIO {
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum MailJournalDrainPolicy {
    static let maximumUnmatchedAge: TimeInterval = 7 * 24 * 60 * 60

    static func shouldAcknowledgeUnmatched(
        publishedContactRevision: Int?,
        currentContactRevision: Int,
        receivedAt: Date,
        now: Date = Date()
    ) -> Bool {
        publishedContactRevision == currentContactRevision
            || receivedAt <= now.addingTimeInterval(-maximumUnmatchedAge)
    }
}

enum MailThumbnailCachePolicy {
    static func revisionAfterReload(
        cachedRevision: Int?,
        identityMinted: Bool,
        mintedFromRevision: Int?,
        currentRevision: Int
    ) -> Int? {
        guard identityMinted,
              let mintedFromRevision,
              cachedRevision == mintedFromRevision
        else { return cachedRevision }
        // Repository metadata proves this exact revision changed only the
        // private identity URL, never Contacts photo bytes.
        return currentRevision
    }
}

/// Exact same address canonicalization the extension cache uses. The package
/// email index intentionally applies a narrower normalization and therefore
/// cannot safely decide whether a journal sender is still a known contact.
struct MailContactAddressIndex {
    private var contactIDsByAddress: [String: [ContactID]] = [:]

    init(contacts: [Contact]) {
        for contact in contacts {
            var addressesSeenOnContact = Set<String>()
            for email in contact.emailAddresses {
                guard let address = MailAddressNormalizer.normalize(email.value),
                      addressesSeenOnContact.insert(address).inserted
                else { continue }
                contactIDsByAddress[address, default: []].append(contact.contactID)
            }
        }
    }

    func contactIDs(matching sender: String) -> [ContactID] {
        guard let address = MailAddressNormalizer.normalize(sender) else { return [] }
        return contactIDsByAddress[address] ?? []
    }
}

/// The cache update transaction kept separate from the controller so forward
/// compatibility and no-op writes can be regression tested without booting a
/// repository. A cache whose newer breaking format has no readable address
/// index is just as authoritative as `.newerFormat`: this build must not
/// downgrade either form.
enum MailContactCachePublication {
    enum Outcome: Equatable {
        case written
        case unchanged
        case preservedNewer(version: Int)
        case failed(errorType: String)
    }

    static func publish(
        _ candidate: MailContactSnapshot,
        to store: MailContactCacheStore
    ) async -> Outcome {
        var snapshot = candidate
        do {
            let existing = try await MailBridgeBlockingIO.run {
                try store.read()
            }
            switch existing {
            case .current(let current):
                snapshot.generatedAt = current.generatedAt
                guard snapshot != current else { return .unchanged }
            case .newerFormat(let version, _):
                return .preservedNewer(version: version)
            case nil:
                break
            }
        } catch MailHandoffError.unsupportedVersion(let version) {
            return .preservedNewer(version: version)
        } catch is DecodingError {
            // A damaged current-format file is recoverable by replacement.
        } catch {
            // A read failure is not proof that the file is damaged. In
            // particular, never replace bytes that may simply be temporarily
            // inaccessible to this process.
            return .failed(errorType: String(reflecting: type(of: error)))
        }

        snapshot.generatedAt = Date()
        let snapshotToWrite = snapshot
        do {
            try await MailBridgeBlockingIO.run {
                try store.write(snapshotToWrite)
            }
            return .written
        } catch {
            return .failed(errorType: String(reflecting: type(of: error)))
        }
    }
}

/// Pure input to the cache projection. Keeping the projection independent of
/// repository I/O makes its address/reason/compose-field behavior testable.
struct MailSnapshotContact: Sendable {
    let contact: Contact
    let thumbnail: Data?
    let highlightReasons: Set<MailHighlightReason>
}

enum MailContactSnapshotBuilder {
    /// A single contact thumbnail is never allowed to dominate the handoff.
    static let maximumThumbnailByteCount = 256 * 1_024
    /// Charged once per normalized address because the plist stores one
    /// summary value per address key.
    static let maximumTotalThumbnailByteCount = 8 * 1_024 * 1_024

    static func build(
        _ contacts: [MailSnapshotContact],
        generatedAt: Date
    ) -> MailContactSnapshot {
        var snapshot = MailContactSnapshot(generatedAt: generatedAt)
        let ordered = contacts.map { candidate in
            (candidate: candidate, key: sortKey(candidate))
        }.sorted { $0.key < $1.key }
        var remainingThumbnailBytes = maximumTotalThumbnailByteCount
        for decorated in ordered {
            let candidate = decorated.candidate
            let addresses = Array(Set(candidate.contact.emailAddresses.compactMap {
                MailAddressNormalizer.normalize($0.value)
            })).sorted()
            guard !addresses.isEmpty else { continue }
            let thumbnail: Data?
            if let data = candidate.thumbnail,
               data.count <= maximumThumbnailByteCount,
               data.isEmpty || addresses.count <= remainingThumbnailBytes / data.count {
                let charged = data.count * addresses.count
                thumbnail = data
                remainingThumbnailBytes -= charged
            } else {
                thumbnail = nil
            }
            let fallbackName = addresses[0]
            let summary = MailContactSummary(
                displayName: nonempty(candidate.contact.displayName) ?? fallbackName,
                organization: nonempty(candidate.contact.organizationName),
                jobTitle: nonempty(candidate.contact.jobTitle),
                thumbnail: thumbnail,
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
            thumbnailFingerprint(candidate.thumbnail),
            candidate.highlightReasons.map(\.rawValue).sorted().joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")
    }

    private static func thumbnailFingerprint(_ data: Data?) -> String {
        guard let data else { return "" }
        let digest = SHA256.hash(data: data)
        return "\(data.count):" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
