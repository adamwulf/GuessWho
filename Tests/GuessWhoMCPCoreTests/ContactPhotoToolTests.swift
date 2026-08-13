import XCTest
import GuessWhoSync
import GuessWhoSyncTesting
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Contact-photo tool parity tests over the PRODUCTION dispatch stack
/// (`MCPProductionFixture`): a real `ContactsRepository` + `GuessWhoSync` over a
/// real on-disk `FileSystemSidecarStore` supply the previous-photo snapshot,
/// and the substituted OS boundary (`RecordingContactStore`) injects the photo
/// write fault the failure test needs AFTER the snapshot has landed.
///
/// A handful of tests exercise adapter quirks the in-memory production store
/// cannot model — a photo READ fault, Contacts TRANSCODING a write, an adapter
/// reporting a cleared photo as empty bytes — and those stay on the fake
/// `Fixture` from Fakes.swift, each labelled with why.
@MainActor
final class ContactPhotoToolTests: XCTestCase {
    private let jpegA = Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02])
    private let jpegB = Data([0xff, 0xd8, 0xff, 0xe1, 0x03, 0x04])

    // MARK: - Fixtures

    /// A writable production fixture. Ada (reconciled, carrying her GuessWho
    /// URL) is the photo subject; her wire id is `adaGuessWhoID`.
    private func productionFixture(limit: Int = 30) async throws -> MCPProductionFixture {
        let fixture = try await MCPProductionFixture.make(writeLimitPerWindow: limit)
        fixture.gates.mcpAccess = .readWrite
        fixture.gates.cliAccess = .readWrite
        return fixture
    }

    /// A writable FAKE fixture (Fakes.swift) for the adapter-quirk tests that
    /// have no production analogue.
    private func legacyFakeFixture(limit: Int = 30) -> Fixture {
        let fixture = Fixture.make(writeLimitPerWindow: limit)
        fixture.gates.mcpAccess = .readWrite
        fixture.gates.cliAccess = .readWrite
        return fixture
    }

    /// The fake fixture's reconciled person, resolved through the dispatcher.
    private func janeID(_ fixture: Fixture) async throws -> String {
        let response = await fixture.dispatcher.handle(.contactsSearch(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            query: "jane", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response,
              let id = page.items.first(where: { $0.name == "Jane Doe" })?.id
        else { throw XCTSkip("Jane fixture missing") }
        return id
    }

    private func errorCode(_ response: WireResponse?) -> WireErrorCode? {
        response?.errorPayload?.code
    }

    // MARK: - Production-backed dispatch tests

    func testSetGetReplaceAndReservedPreviousPhotoPath() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID

        let set = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/jpeg",
            dataBase64: jpegA.base64EncodedString(), idempotencyToken: nil))
        guard case .acknowledged(_, _, let setMessage) = set else {
            return XCTFail("expected photo-set acknowledgement")
        }
        XCTAssertEqual(setMessage, WireAckMessage.photoSet)

        let get = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
        guard case .contactPhoto(_, _, let photo) = get else {
            return XCTFail("expected photo")
        }
        XCTAssertTrue(photo.present)
        XCTAssertEqual(photo.mediaType, "image/jpeg")
        XCTAssertEqual(Data(base64Encoded: photo.dataBase64 ?? ""), jpegA)

        let replace = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/jpeg",
            dataBase64: jpegB.base64EncodedString(), idempotencyToken: nil))
        guard case .acknowledged(_, _, let replaceMessage) = replace else {
            return XCTFail("expected photo-replace acknowledgement")
        }
        XCTAssertEqual(replaceMessage, WireAckMessage.photoSet)

        // The prior photo (jpegA) was snapshotted to the on-disk sidecar before
        // the replacement (jpegB) — real GuessWhoSync previous-photo behavior.
        let prior = try fixture.storedPreviousPhoto(forGuessWhoID: ada)
        XCTAssertEqual(prior, jpegA)
        let internalFields = try fixture.storedFields(forGuessWhoID: ada)
        XCTAssertTrue(internalFields.contains {
            $0.field == "previousPhoto" && $0.type == .blob
        })

        // …yet the reserved snapshot field never surfaces in the user list.
        let visible = await fixture.dispatcher.handle(.contactsListCustomFields(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, limit: nil, cursor: nil))
        guard case .customFieldPage(_, _, let page) = visible else {
            return XCTFail("expected custom-field page")
        }
        XCTAssertFalse(page.items.contains { $0.name == "previousPhoto" })

        let audit = await fixture.storedAuditEntries()
        XCTAssertEqual(audit.filter { $0.action == .editContact }.count, 2)
    }

    func testDeletePreservesCurrentPhotoAndIsIdempotentWhenAbsent() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        await fixture.seedPhoto(jpegA, forLocalID: MCPProductionFixture.adaLocalID)

        let deleted = await fixture.dispatcher.handle(.contactsDeletePhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, idempotencyToken: nil))
        guard case .acknowledged(_, _, let deletedMessage) = deleted else {
            return XCTFail("expected photo-delete acknowledgement")
        }
        XCTAssertEqual(deletedMessage, WireAckMessage.photoDeleted)
        // The just-deleted photo was snapshotted before removal.
        let prior = try fixture.storedPreviousPhoto(forGuessWhoID: ada)
        XCTAssertEqual(prior, jpegA)
        let committedAfterDelete = await fixture.store.committedPhotoWrites
        XCTAssertEqual(committedAfterDelete.count, 1)
        XCTAssertEqual(committedAfterDelete.last?.cleared, true)

        let again = await fixture.dispatcher.handle(.contactsDeletePhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, idempotencyToken: nil))
        guard case .acknowledged(_, _, let repeatedMessage) = again else {
            return XCTFail("expected idempotent photo-delete acknowledgement")
        }
        XCTAssertEqual(repeatedMessage, WireAckMessage.photoDeleted)
        let finalCommitted = await fixture.store.committedPhotoWrites
        XCTAssertEqual(finalCommitted.count, 1, "deleting an absent photo is a no-op")
    }

    func testSetRejectsInvalidMismatchedAndOversizedPayloads() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID

        let invalid = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/jpeg", dataBase64: "%%%",
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(invalid), .invalidParams)

        let mismatch = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/png",
            dataBase64: jpegA.base64EncodedString(), idempotencyToken: nil))
        XCTAssertEqual(errorCode(mismatch), .invalidParams)

        let oversized = Data(repeating: 0xff, count: WireEnvironment.maxContactPhotoBytes + 1)
        let tooLarge = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/jpeg",
            dataBase64: oversized.base64EncodedString(), idempotencyToken: nil))
        XCTAssertEqual(errorCode(tooLarge), .tooLarge)
        // Nothing rejected at validation ever reached the store boundary.
        let attempts = await fixture.store.photoWriteAttempts
        XCTAssertTrue(attempts.isEmpty)
    }

    func testEverySupportedMediaTypeIsAcceptedAndReported() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        let cases: [(mediaType: String, data: Data)] = [
            ("image/jpeg", Data([0xff, 0xd8, 0xff, 0xe0])),
            ("image/png", Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
            ("image/gif", Data("GIF89a".utf8)),
            ("image/webp", Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))),
        ]
        let heifCases = [
            "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1",
        ].map { brand in
            (mediaType: "image/heic", data: Data([0, 0, 0, 0] + Array("ftyp\(brand)".utf8)))
        }

        for item in cases + heifCases {
            let set = await fixture.dispatcher.handle(.contactsSetPhoto(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                contactId: ada, mediaType: item.mediaType,
                dataBase64: item.data.base64EncodedString(), idempotencyToken: nil))
            guard case .acknowledged(_, _, let message) = set else {
                XCTFail("set should acknowledge \(item.mediaType)")
                continue
            }
            XCTAssertEqual(message, WireAckMessage.photoSet)

            let get = await fixture.dispatcher.handle(.contactsGetPhoto(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
            guard case .contactPhoto(_, _, let photo) = get else {
                XCTFail("get should return \(item.mediaType)")
                continue
            }
            XCTAssertEqual(photo.mediaType, item.mediaType)
            XCTAssertEqual(Data(base64Encoded: photo.dataBase64 ?? ""), item.data)
        }
    }

    func testGetRejectsUnsupportedStoredImageFormatAsReadFailure() async throws {
        let fixture = try await MCPProductionFixture.make()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        await fixture.seedPhoto(Data("not-an-image".utf8), forLocalID: MCPProductionFixture.adaLocalID)
        let response = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
        XCTAssertEqual(errorCode(response), .readFailed)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.unsupportedStoredPhoto)
    }

    func testGetEnforcesRawAndEncodedResponseBounds() async throws {
        let fixture = try await MCPProductionFixture.make()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        var bounded = Data(repeating: 0, count: WireEnvironment.maxContactPhotoBytes)
        bounded.replaceSubrange(0..<3, with: [0xff, 0xd8, 0xff])
        await fixture.seedPhoto(bounded, forLocalID: MCPProductionFixture.adaLocalID)
        let response = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
        guard case .contactPhoto(_, _, let photo) = response else {
            return XCTFail("the documented maximum must fit the response envelope")
        }
        XCTAssertEqual(photo.byteCount, WireEnvironment.maxContactPhotoBytes)
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(response).count,
            WireEnvironment.maxResponsePayloadBytes)

        var oversized = bounded
        oversized.append(0)
        await fixture.seedPhoto(oversized, forLocalID: MCPProductionFixture.adaLocalID)
        let rejected = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
        XCTAssertEqual(errorCode(rejected), .tooLarge)
    }

    func testPermissionAccessModeWriteBudgetAndTypedSaveErrors() async throws {
        let readOnly = try await MCPProductionFixture.make()
        defer { readOnly.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        let deniedWrite = await readOnly.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(deniedWrite), .readOnly)

        readOnly.gates.contactsAuthorized = false
        let deniedRead = await readOnly.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
        XCTAssertEqual(errorCode(deniedRead), .permissionDenied)

        let budgeted = try await productionFixture(limit: 1)
        defer { budgeted.cleanUp() }
        let firstBudgeted = await budgeted.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        guard case .acknowledged(_, _, let firstBudgetedMessage) = firstBudgeted else {
            return XCTFail("the first budgeted photo write must succeed")
        }
        XCTAssertEqual(firstBudgetedMessage, WireAckMessage.photoSet)
        let firstBudgetedCommits = await budgeted.store.committedPhotoWrites
        XCTAssertEqual(firstBudgetedCommits.count, 1)
        let busy = await budgeted.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegB.base64EncodedString(),
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(busy), .busy)

        let failing = try await productionFixture()
        defer { failing.cleanUp() }
        await failing.store.failNextPhotoWrite(
            with: NSError(domain: "CNErrorDomain", code: 100, userInfo: [:]))
        let permissionFailure = await failing.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(permissionFailure), .permissionDenied)
    }

    func testSetIdempotencyTokenAndIntrinsicIdempotencyAvoidDuplicateWrites() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        let first = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: "photo-1", contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: "photo-token"))
        guard case .acknowledged(_, _, let firstMessage) = first else {
            return XCTFail("expected first photo-set acknowledgement")
        }
        XCTAssertEqual(firstMessage, WireAckMessage.photoSet)
        let auditAfterFirst = await fixture.storedAuditEntries()
        XCTAssertEqual(auditAfterFirst.filter { $0.action == .editContact }.count, 1)
        let replay = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: "photo-2", contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegB.base64EncodedString(),
            idempotencyToken: "photo-token"))
        guard case .acknowledged(_, _, let replayMessage) = replay else {
            return XCTFail("expected cached photo-set acknowledgement")
        }
        XCTAssertEqual(replayMessage, WireAckMessage.photoSet)
        var committed = await fixture.store.committedPhotoWrites
        XCTAssertEqual(committed.count, 1)
        let stored = try await fixture.storedPhoto(forLocalID: MCPProductionFixture.adaLocalID)
        XCTAssertEqual(stored, jpegA, "a replay returns the original outcome")
        let auditAfterReplay = await fixture.storedAuditEntries()
        XCTAssertEqual(auditAfterReplay, auditAfterFirst)

        let intrinsicReplay = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: "photo-3", contactId: ada,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        guard case .acknowledged(_, _, let intrinsicMessage) = intrinsicReplay else {
            return XCTFail("expected intrinsic photo-set acknowledgement")
        }
        XCTAssertEqual(intrinsicMessage, WireAckMessage.photoSet)
        committed = await fixture.store.committedPhotoWrites
        XCTAssertEqual(committed.count, 1, "identical bytes are a no-op without a token too")
        let auditAfterIntrinsicReplay = await fixture.storedAuditEntries()
        XCTAssertEqual(auditAfterIntrinsicReplay, auditAfterFirst)
    }

    /// The NEW production-backed snapshot-then-fault coverage. Ada already has a
    /// photo; the store rejects the write (the Cocoa 134092 store-rejection
    /// family) AFTER `setContactPhoto` has snapshotted the prior bytes. The
    /// snapshot must be durable through GuessWhoSync, the live photo must be
    /// untouched, the cache/reload must stay honest, the returned error must be
    /// typed + non-leaking + unaudited, and a retry (a failed write is never
    /// idempotency-cached) must apply the new photo.
    func testSetPhotoSnapshotSurvivesInjectedWriteFailureAndRetries() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let ada = MCPProductionFixture.adaGuessWhoID
        await fixture.seedPhoto(jpegA, forLocalID: MCPProductionFixture.adaLocalID)

        let rejection = NSError(
            domain: "NSCocoaErrorDomain", code: 134092,
            userInfo: [NSLocalizedDescriptionKey: MCPProductionFixture.adaLocalID])
        await fixture.store.failNextPhotoWrite(with: rejection)

        let response = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/jpeg",
            dataBase64: jpegB.base64EncodedString(), idempotencyToken: "photo-retry"))
        XCTAssertEqual(errorCode(response), .writeFailed)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.writeFailed)

        // Snapshot durable through sync: the prior image reached the on-disk
        // sidecar BEFORE the write was rejected.
        let snapshot = try fixture.storedPreviousPhoto(forGuessWhoID: ada)
        XCTAssertEqual(snapshot, jpegA, "the previousPhoto snapshot is durable through sync")

        // Live photo unchanged: the rejected write left the bytes intact.
        let live = try await fixture.storedPhoto(forLocalID: MCPProductionFixture.adaLocalID)
        XCTAssertEqual(live, jpegA, "a failed write leaves the live photo intact")

        // The boundary recorded the attempt but committed nothing.
        let attempts = await fixture.store.photoWriteAttempts
        let committed = await fixture.store.committedPhotoWrites
        XCTAssertEqual(attempts, [RecordingContactStore.PhotoWrite(
            localID: MCPProductionFixture.adaLocalID, cleared: false)])
        XCTAssertTrue(committed.isEmpty)

        // Cache/reload honesty: a full refresh + fresh GET still returns the
        // untouched photo — the failed write never changed what is served.
        await fixture.reload()
        let get = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(), contactId: ada))
        guard case .contactPhoto(_, _, let photo) = get else { return XCTFail("expected photo") }
        XCTAssertEqual(Data(base64Encoded: photo.dataBase64 ?? ""), jpegA)

        // Typed error is non-leaking and the failed write is never audited.
        let entries = await fixture.storedAuditEntries()
        XCTAssertFalse(entries.contains { $0.action == .editContact })
        XCTAssertFalse(response?.wireJSON.contains(MCPProductionFixture.adaLocalID) == true)
        XCTAssertFalse(response?.agentVisibleText.contains(MCPProductionFixture.adaLocalID) == true)

        // Idempotency retry: the failed write was NOT cached, so re-sending the
        // same token re-executes (the one-shot fault has cleared) and the new
        // photo finally lands, while the snapshot still holds the original.
        let retry = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: ada, mediaType: "image/jpeg",
            dataBase64: jpegB.base64EncodedString(), idempotencyToken: "photo-retry"))
        guard case .acknowledged(_, _, let retryMessage) = retry else {
            return XCTFail("expected successful retry acknowledgement")
        }
        XCTAssertEqual(retryMessage, WireAckMessage.photoSet)
        let healed = try await fixture.storedPhoto(forLocalID: MCPProductionFixture.adaLocalID)
        XCTAssertEqual(healed, jpegB, "the retry applies the new photo")
        let snapshotAfter = try fixture.storedPreviousPhoto(forGuessWhoID: ada)
        XCTAssertEqual(snapshotAfter, jpegA, "the retry snapshots the still-current prior photo")
        let attemptsAfterRetry = await fixture.store.photoWriteAttempts
        let commitsAfterRetry = await fixture.store.committedPhotoWrites
        XCTAssertEqual(attemptsAfterRetry.count, 2)
        XCTAssertEqual(commitsAfterRetry.count, 1)
        let finalEntries = await fixture.storedAuditEntries()
        let finalAudit = finalEntries.filter { $0.action == .editContact }
        XCTAssertEqual(finalAudit.count, 1)
        XCTAssertEqual(finalAudit.first?.priorValue, "photo (6 bytes)")
        XCTAssertEqual(finalAudit.first?.newValue, "photo (image/jpeg, 6 bytes)")
    }

    // MARK: - Fake-only adapter quirks (no production analogue)

    func testGetDistinguishesNoPhotoFromFailure() async throws {
        let production = try await MCPProductionFixture.make()
        defer { production.cleanUp() }
        let absent = await production.dispatcher.handle(.contactsGetPhoto(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            contactId: MCPProductionFixture.adaGuessWhoID))
        guard case .contactPhoto(_, _, let photo) = absent else {
            return XCTFail("expected production no-photo result")
        }
        XCTAssertFalse(photo.present)
        XCTAssertNil(photo.mediaType)
        XCTAssertNil(photo.dataBase64)
        XCTAssertEqual(photo.byteCount, 0)

        // The read-failure half needs a one-shot photo-read fault that the
        // recording OS boundary does not expose, so only this branch stays fake.
        let fixture = Fixture.make()
        let jane = try await janeID(fixture)
        fixture.contacts.nextContactStoreError = NSError(
            domain: "PhotoRead", code: 1, userInfo: [:])
        let failed = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        XCTAssertEqual(errorCode(failed), .readFailed)
    }

    func testDeleteVerificationAcceptsEmptyBytesAsNoPhoto() async throws {
        // Fake-only: an adapter that represents a CLEARED photo as empty bytes
        // on the verification read-back instead of nil. The production store
        // removes the bytes outright, so this quirk has no production analogue.
        let fixture = legacyFakeFixture()
        let jane = try await janeID(fixture)
        fixture.contacts.photoDataByLocalID[Sentinels.localID] = jpegA
        fixture.contacts.photoDeleteLeavesEmptyData = true

        let response = await fixture.dispatcher.handle(.contactsDeletePhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = response else {
            return XCTFail("expected empty-byte delete acknowledgement")
        }
        XCTAssertEqual(message, WireAckMessage.photoDeleted)
    }

    func testSetVerificationAcceptsContactsTranscodingTheImage() async throws {
        // Fake-only: simulates Contacts TRANSCODING the supplied image before the
        // verification read-back. The in-memory production store has no
        // transcoder, so this adapter quirk stays on the fake source.
        let fixture = legacyFakeFixture()
        let jane = try await janeID(fixture)
        let transcoded = Data([0xff, 0xd8, 0xff, 0xee, 0x09])
        fixture.contacts.photoWriteReplacementData = transcoded

        let response = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, mediaType: "image/jpeg",
            dataBase64: jpegA.base64EncodedString(), idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = response else {
            return XCTFail("expected transcoded photo-set acknowledgement")
        }
        XCTAssertEqual(message, WireAckMessage.photoSet)
        let stored = fixture.contacts.photoDataByLocalID[Sentinels.localID]
        XCTAssertEqual(stored, transcoded)
    }
}
