#if targetEnvironment(macCatalyst)

import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

@MainActor
@Suite("Mail contact snapshot projection")
struct MailBridgeControllerTests {
    @Test
    func recordedActivityBuildsASafeMailLink() throws {
        let activity = try #require(MailActivity(
            senderAddress: "ada@example.com",
            subject: "Hello",
            receivedAt: Date(timeIntervalSince1970: 1_000),
            messageID: "<ABC.123@Example.COM>",
            mailURL: "https://attacker.invalid/not-used"
        ))

        let link = try #require(MailActivityMailLink.url(for: activity))
        #expect(link.scheme == "message")
        #expect(link.absoluteString == "message://%3CABC.123@example.com%3E")
    }

    @Test
    func unmatchedMailIsDroppedOnlyAfterTheCurrentContactsWerePublished() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(!MailJournalDrainPolicy.shouldAcknowledgeUnmatched(
            publishedContactRevision: nil,
            currentContactRevision: 3,
            receivedAt: now,
            now: now
        ))
        #expect(!MailJournalDrainPolicy.shouldAcknowledgeUnmatched(
            publishedContactRevision: 2,
            currentContactRevision: 3,
            receivedAt: now,
            now: now
        ))
        #expect(MailJournalDrainPolicy.shouldAcknowledgeUnmatched(
            publishedContactRevision: 3,
            currentContactRevision: 3,
            receivedAt: now,
            now: now
        ))
        #expect(MailJournalDrainPolicy.shouldAcknowledgeUnmatched(
            publishedContactRevision: nil,
            currentContactRevision: 3,
            receivedAt: now.addingTimeInterval(-MailJournalDrainPolicy.maximumUnmatchedAge),
            now: now
        ))
    }

    @Test
    func thumbnailRevisionCarriesOnlyAcrossTheExactMailIdentityMint() {
        #expect(MailIdentityMintRevisionPolicy.isExact(
            identityMinted: true,
            fromRevision: 4,
            toRevision: 5,
            currentRevision: 5
        ))
        #expect(!MailIdentityMintRevisionPolicy.isExact(
            identityMinted: true,
            fromRevision: 4,
            toRevision: 6,
            currentRevision: 6
        ))
        #expect(!MailIdentityMintRevisionPolicy.isExact(
            identityMinted: true,
            fromRevision: 4,
            toRevision: 5,
            currentRevision: 6
        ))
        #expect(MailThumbnailCachePolicy.revisionAfterReload(
            cachedRevision: 4,
            isExactIdentityMint: true,
            mintedFromRevision: 4,
            mintedToRevision: 5
        ) == 5)
        #expect(MailThumbnailCachePolicy.revisionAfterReload(
            cachedRevision: 3,
            isExactIdentityMint: true,
            mintedFromRevision: 4,
            mintedToRevision: 5
        ) == 3)
        #expect(MailThumbnailCachePolicy.revisionAfterReload(
            cachedRevision: 4,
            isExactIdentityMint: false,
            mintedFromRevision: 4,
            mintedToRevision: 5
        ) == 4)
        #expect(MailThumbnailCachePolicy.revisionAfterReload(
            cachedRevision: nil,
            isExactIdentityMint: false,
            mintedFromRevision: 4,
            mintedToRevision: 6
        ) == nil)
    }

    @Test
    func projectionCarriesComposeDetailsAndHighlightReasons() throws {
        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            jobTitle: "Mathematician",
            organizationName: "Analytical Engines",
            emailAddresses: [LabeledValue(label: "work", value: " ADA@Example.COM ")]
        )
        let thumbnail = Data([0x01, 0x02, 0x03])
        let snapshot = MailContactSnapshotBuilder.build([
            MailSnapshotContact(
                contact: contact,
                thumbnail: thumbnail,
                highlightReasons: [.favoriteContact, .favoriteGroupMember]
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_000))

        let summary = try #require(snapshot.summaries(forAddress: "ada@example.com").first)
        #expect(summary.displayName == "Ada Lovelace")
        #expect(summary.organization == "Analytical Engines")
        #expect(summary.jobTitle == "Mathematician")
        #expect(summary.thumbnail == thumbnail)
        #expect(summary.highlightReasons == [.favoriteContact, .favoriteGroupMember])
    }

    @Test
    func sharedAddressKeepsEveryMatchingContact() {
        let first = Contact(
            givenName: "First",
            emailAddresses: [LabeledValue(label: "home", value: "shared@example.com")]
        )
        let second = Contact(
            givenName: "Second",
            emailAddresses: [LabeledValue(label: "work", value: "SHARED@example.com")]
        )
        let snapshot = MailContactSnapshotBuilder.build([
            MailSnapshotContact(
                contact: second,
                thumbnail: nil,
                highlightReasons: [.favoriteOrganizationMember]
            ),
            MailSnapshotContact(
                contact: first,
                thumbnail: nil,
                highlightReasons: []
            ),
        ], generatedAt: .distantPast)

        let summaries = snapshot.summaries(forAddress: "shared@example.com")
        #expect(summaries.map(\.displayName) == ["First", "Second"])
        #expect(summaries[0].isHighlighted == false)
        #expect(summaries[1].highlightReasons == [.favoriteOrganizationMember])
    }

    @Test
    func projectionIsStableAndSkipsContactsWithoutEmail() {
        let alpha = Contact(
            givenName: "Alpha",
            emailAddresses: [LabeledValue(label: "home", value: "alpha@example.com")]
        )
        let beta = Contact(
            givenName: "Beta",
            emailAddresses: [LabeledValue(label: "home", value: "beta@example.com")]
        )
        let noEmail = Contact(givenName: "No Email")
        let inputs = [
            MailSnapshotContact(contact: beta, thumbnail: nil, highlightReasons: []),
            MailSnapshotContact(contact: noEmail, thumbnail: nil, highlightReasons: [.favoriteContact]),
            MailSnapshotContact(contact: alpha, thumbnail: nil, highlightReasons: []),
        ]

        let forward = MailContactSnapshotBuilder.build(inputs, generatedAt: .distantPast)
        let reverse = MailContactSnapshotBuilder.build(Array(inputs.reversed()), generatedAt: .distantPast)
        #expect(forward == reverse)
        #expect(forward.summaries(forAddress: "alpha@example.com").count == 1)
        #expect(forward.summaries(forAddress: "beta@example.com").count == 1)
    }

    @Test
    func addressIndexUsesTheMailCacheNormalizer() {
        let contact = Contact(
            givenName: "Ada",
            emailAddresses: [
                LabeledValue(label: "work", value: "Ada Lovelace <ADA@Example.COM.>")
            ],
            urlAddresses: [
                LabeledValue(
                    label: "GuessWho",
                    value: "guesswho://contact/00000000-0000-0000-0000-000000000001"
                )
            ]
        )
        let index = MailContactAddressIndex(contacts: [contact])

        #expect(index.contactIDs(matching: "mailto:ada@example.com?subject=Hello") == [contact.contactID])
    }

    @Test
    func projectionBoundsThumbnailBytesDeterministically() {
        let thumbnail = Data(repeating: 0x5a, count: MailContactSnapshotBuilder.maximumThumbnailByteCount)
        let contacts = (0..<40).map { index in
            MailSnapshotContact(
                contact: Contact(
                    givenName: "Person \(index)",
                    emailAddresses: [
                        LabeledValue(label: "work", value: "person\(index)@example.com")
                    ]
                ),
                thumbnail: thumbnail,
                highlightReasons: []
            )
        }

        let forward = MailContactSnapshotBuilder.build(contacts, generatedAt: .distantPast)
        let reverse = MailContactSnapshotBuilder.build(Array(contacts.reversed()), generatedAt: .distantPast)
        #expect(forward == reverse)
        let kept = (0..<40).filter { index in
            forward.summaries(forAddress: "person\(index)@example.com").first?.thumbnail != nil
        }
        #expect(kept.count == 32)
    }

    @Test
    func publicationDoesNotRewriteAnEquivalentSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contacts.plist")
        let store = MailContactCacheStore(fileURL: url)
        var stored = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 100))
        stored.add(MailContactSummary(displayName: "Ada"), forAddresses: ["ada@example.com"])
        try store.write(stored)
        let before = try Data(contentsOf: url)

        var candidate = stored
        candidate.generatedAt = Date(timeIntervalSince1970: 200)
        let outcome = await MailContactCachePublication.publish(candidate, to: store)

        #expect(outcome == .unchanged)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test
    func publicationPreservesAnUnreadableNewerCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contacts.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["version": 999, "futureIndex": ["opaque": true]],
            format: .binary,
            options: 0
        )
        try data.write(to: url)
        let store = MailContactCacheStore(fileURL: url)

        let outcome = await MailContactCachePublication.publish(
            MailContactSnapshot(generatedAt: .distantPast),
            to: store
        )

        #expect(outcome == .preservedNewer(version: 999))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test
    func bridgePublishesContactsAndDrainsKnownSender() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mail-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guessWhoID = "10000000-0000-4000-8000-000000000001"
        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            emailAddresses: [LabeledValue(label: "work", value: "Ada <ADA@example.com.>")],
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/\(guessWhoID)")
            ]
        )
        let service = SyncService(
            contactsAdapter: MailBridgeContactStore(contacts: [contact]),
            eventsAdapter: MailBridgeEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "mail-bridge-test",
            contactCursorURL: root.appendingPathComponent("cursor")
        )
        let center = NotificationCenter()
        let repository = service.makeContactsRepository(notificationCenter: center)
        await repository.reload()

        let cacheStore = MailContactCacheStore(
            fileURL: root.appendingPathComponent("contact-cache.plist")
        )
        let journalURL = root.appendingPathComponent("incoming-messages.jsonl")
        let journal = MailIncomingJournal(fileURL: journalURL)
        let messageID = try #require(MailMessageID.normalize("bridge@example.com"))
        _ = try journal.append(MailIncomingMessage(
            sender: "mailto:ada@example.com",
            subject: "Integration",
            receivedAt: Date(timeIntervalSince1970: 2_000),
            messageID: messageID,
            messageURL: URL(string: "https://attacker.invalid/not-used")
        ))

        let controller = MailBridgeController(
            service: service,
            repository: repository,
            notificationCenter: center,
            cacheStore: cacheStore,
            journal: journal,
            journalNotificationName: nil
        )
        controller.bootstrap()
        defer { controller.shutdown() }

        let contactID = try #require(repository.contacts.first?.contactID)
        try await waitUntil {
            await repository.mailActivities(for: contactID).map(\.messageID) == ["bridge@example.com"]
        }
        try await waitUntil {
            guard case .current(let snapshot) = try? cacheStore.read() else { return false }
            return snapshot.summaries(forAddress: "ada@example.com").map(\.displayName)
                == ["Ada Lovelace"]
        }
        let contents = try #require(try cacheStore.read())
        guard case .current(let snapshot) = contents else {
            Issue.record("Expected a current cache snapshot")
            return
        }
        #expect(snapshot.summaries(forAddress: "ada@example.com").map(\.displayName) == ["Ada Lovelace"])
        try await waitUntil {
            ((try? Data(contentsOf: journalURL)) ?? Data()).isEmpty
        }
    }

    @Test
    func bridgeAcknowledgesUnmatchedSenderAfterPublishingCurrentContacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mail-unmatched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let guessWhoID = "20000000-0000-4000-8000-000000000002"
        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            emailAddresses: [LabeledValue(label: "work", value: "ada@example.com")],
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: "guesswho://contact/\(guessWhoID)")
            ]
        )
        let service = SyncService(
            contactsAdapter: MailBridgeContactStore(contacts: [contact]),
            eventsAdapter: MailBridgeEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "mail-bridge-unmatched-test",
            contactCursorURL: root.appendingPathComponent("cursor")
        )
        let center = NotificationCenter()
        let repository = service.makeContactsRepository(notificationCenter: center)
        await repository.reload()

        let cacheStore = MailContactCacheStore(
            fileURL: root.appendingPathComponent("contact-cache.plist")
        )
        let journalURL = root.appendingPathComponent("incoming-messages.jsonl")
        let journal = MailIncomingJournal(fileURL: journalURL)
        let messageID = try #require(MailMessageID.normalize("missing@example.com"))
        _ = try journal.append(MailIncomingMessage(
            sender: "missing@example.com",
            subject: "No longer known",
            receivedAt: Date(),
            messageID: messageID,
            messageURL: nil
        ))

        let controller = MailBridgeController(
            service: service,
            repository: repository,
            notificationCenter: center,
            cacheStore: cacheStore,
            journal: journal,
            journalNotificationName: nil
        )
        controller.bootstrap()
        defer { controller.shutdown() }

        try await waitUntil {
            guard case .current = try? cacheStore.read() else { return false }
            return ((try? Data(contentsOf: journalURL)) ?? Data()).isEmpty
        }
        let contactID = try #require(repository.contacts.first?.contactID)
        #expect(await repository.mailActivities(for: contactID).isEmpty)
    }

    @Test
    func failedFavoriteGroupMemberReadPreservesTheExistingCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mail-group-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            emailAddresses: [LabeledValue(label: "work", value: "ada@example.com")],
            urlAddresses: [
                LabeledValue(
                    label: "GuessWho",
                    value: "guesswho://contact/30000000-0000-4000-8000-000000000003"
                )
            ]
        )
        let group = ContactGroup(localID: "favorites", name: "Favorites")
        let store = MailBridgeContactStore(
            contacts: [contact],
            groups: [group],
            membersByGroupID: [group.localID: [contact]],
            memberLocalIDsByGroupID: [group.localID: [""]]
        )
        let service = SyncService(
            contactsAdapter: store,
            eventsAdapter: MailBridgeEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "mail-bridge-group-failure-test",
            contactCursorURL: root.appendingPathComponent("cursor")
        )
        let center = NotificationCenter()
        let repository = service.makeContactsRepository(notificationCenter: center)
        await repository.reload()
        await repository.loadGroups()
        _ = try await repository.setGroupFavorite(true, for: group)
        await store.setFailMemberFetch(true)

        let cacheURL = root.appendingPathComponent("contact-cache.plist")
        let cacheStore = MailContactCacheStore(fileURL: cacheURL)
        var existing = MailContactSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000))
        existing.add(
            MailContactSummary(displayName: "Sentinel"),
            forAddresses: ["sentinel@example.com"]
        )
        try cacheStore.write(existing)
        let bytesBefore = try Data(contentsOf: cacheURL)

        let controller = MailBridgeController(
            service: service,
            repository: repository,
            notificationCenter: center,
            cacheStore: cacheStore,
            journal: nil,
            journalNotificationName: nil
        )
        controller.bootstrap()
        defer { controller.shutdown() }

        try await waitUntil { await store.memberFetchAttemptCount() > 0 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(try Data(contentsOf: cacheURL) == bytesBefore)
    }

    @Test
    func failedMailWriteIsReleasedForRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mail-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contact = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            emailAddresses: [LabeledValue(label: "work", value: "ada@example.com")]
        )
        let store = MailBridgeContactStore(contacts: [contact], failSaves: true)
        let service = SyncService(
            contactsAdapter: store,
            eventsAdapter: MailBridgeEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "mail-bridge-write-failure-test",
            contactCursorURL: root.appendingPathComponent("cursor")
        )
        let center = NotificationCenter()
        let repository = service.makeContactsRepository(notificationCenter: center)
        await repository.reload()

        let cacheStore = MailContactCacheStore(
            fileURL: root.appendingPathComponent("contact-cache.plist")
        )
        let journalURL = root.appendingPathComponent("incoming-messages.jsonl")
        let journal = MailIncomingJournal(fileURL: journalURL)
        let messageID = try #require(MailMessageID.normalize("retry@example.com"))
        _ = try journal.append(MailIncomingMessage(
            sender: "ada@example.com",
            subject: "Retry me",
            receivedAt: Date(),
            messageID: messageID,
            messageURL: nil
        ))

        let controller = MailBridgeController(
            service: service,
            repository: repository,
            notificationCenter: center,
            cacheStore: cacheStore,
            journal: journal,
            journalNotificationName: nil
        )
        controller.bootstrap()
        defer { controller.shutdown() }

        try await waitUntil { await store.saveAttemptCount() > 0 }
        try await waitUntil { self.journalLineIsUnclaimed(at: journalURL) }

        let retryClaim = try #require(try journal.claimEntries())
        #expect(retryClaim.entries.map(\.messageID) == ["retry@example.com"])
        _ = try journal.release(retryClaim)
    }

    private func journalLineIsUnclaimed(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["claim"] == nil || object["claim"] is NSNull
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private actor MailBridgeContactStore: ContactStoreProtocol {
    private struct MemberFetchFailure: Error {}
    private struct SaveFailure: Error {}

    private var contacts: [Contact]
    private var groups: [ContactGroup]
    private var membersByGroupID: [String: [Contact]]
    private var memberLocalIDsByGroupID: [String: [String]]
    private var failMemberFetch = false
    private var memberFetches = 0
    private var failSaves: Bool
    private var saves = 0

    init(
        contacts: [Contact],
        groups: [ContactGroup] = [],
        membersByGroupID: [String: [Contact]] = [:],
        memberLocalIDsByGroupID: [String: [String]] = [:],
        failSaves: Bool = false
    ) {
        self.contacts = contacts
        self.groups = groups
        self.membersByGroupID = membersByGroupID
        self.memberLocalIDsByGroupID = memberLocalIDsByGroupID
        self.failSaves = failSaves
    }

    func setFailMemberFetch(_ fail: Bool) { failMemberFetch = fail }
    func memberFetchAttemptCount() -> Int { memberFetches }
    func saveAttemptCount() -> Int { saves }

    func fetchAll() async throws -> [Contact] { contacts }
    func fetch(localID: String) async throws -> Contact? {
        // Bridge integration fixtures contain exactly one Contacts record.
        contacts.first
    }
    func save(_ contact: Contact) async throws {
        saves += 1
        if failSaves { throw SaveFailure() }
        if contacts.isEmpty {
            contacts.append(contact)
        } else {
            contacts[0] = contact
        }
    }
    func delete(localID: String) async throws {}
    func create(_ contact: Contact) async throws -> Contact { contact }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .authorized }
    func requestContactsAccess() async -> StoreAccessResult {
        StoreAccessResult(status: .authorized)
    }
    func changes(since token: Data?) async throws -> ContactChangeSet {
        ContactChangeSet(changes: [], newToken: token ?? Data(), requiresFullReload: false)
    }
    func loadImageData(localID: String) async throws -> Data? { nil }
    func loadThumbnailImageData(localID: String) async throws -> Data? { nil }
    func setImageData(localID: String, imageData: Data?) async throws {}
    func fetchAllGroups() async throws -> [ContactGroup] { groups }
    func fetchGroup(localID: String) async throws -> ContactGroup? {
        groups.first { $0.localID == localID }
    }
    func createGroup(name: String) async throws -> ContactGroup {
        ContactGroup(localID: UUID().uuidString, name: name)
    }
    func renameGroup(localID: String, to name: String) async throws {}
    func deleteGroup(localID: String) async throws {}
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        memberFetches += 1
        if failMemberFetch { throw MemberFetchFailure() }
        return membersByGroupID[groupLocalID] ?? []
    }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] {
        memberLocalIDsByGroupID[groupLocalID] ?? []
    }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {}
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {}
}

private final class MailBridgeEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .authorized }
    func requestEventsAccess() async -> StoreAccessResult {
        StoreAccessResult(status: .authorized)
    }
    func fetchEvents(in interval: DateInterval) throws -> [Event] { [] }
    func fetch(eventKitID: String) throws -> Event? { nil }
    func fetchEvents(on day: Date) throws -> [Event] { [] }
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] { [] }
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] { [] }
    func fetch(legacyEventIdentifier: String) throws -> Event? { nil }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event {
        Event(title: title, startDate: startDate, endDate: endDate, isAllDay: isAllDay)
    }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws {}
}

#endif
