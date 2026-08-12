import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

final class ContactPhotoToolTests: XCTestCase {
    private let jpegA = Data([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02])
    private let jpegB = Data([0xff, 0xd8, 0xff, 0xe1, 0x03, 0x04])

    private func writableFixture(limit: Int = 30) async -> Fixture {
        let fixture = await Fixture.make(writeLimitPerWindow: limit)
        await MainActor.run {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        return fixture
    }

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

    func testGetDistinguishesNoPhotoFromFailure() async throws {
        let fixture = await Fixture.make()
        let jane = try await janeID(fixture)

        let absent = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        guard case .contactPhoto(_, _, let photo) = absent else {
            return XCTFail("expected a successful no-photo result")
        }
        XCTAssertFalse(photo.present)
        XCTAssertNil(photo.mediaType)
        XCTAssertNil(photo.dataBase64)
        XCTAssertEqual(photo.byteCount, 0)

        await MainActor.run {
            fixture.contacts.nextContactStoreError = NSError(
                domain: "PhotoRead", code: 1, userInfo: [:])
        }
        let failed = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        XCTAssertEqual(errorCode(failed), .readFailed)
    }

    func testSetGetReplaceAndReservedPreviousPhotoPath() async throws {
        let fixture = await writableFixture()
        let jane = try await janeID(fixture)

        let set = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, mediaType: "image/jpeg",
            dataBase64: jpegA.base64EncodedString(), idempotencyToken: nil))
        XCTAssertNil(set?.errorPayload)

        let get = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        guard case .contactPhoto(_, _, let photo) = get else {
            return XCTFail("expected photo")
        }
        XCTAssertTrue(photo.present)
        XCTAssertEqual(photo.mediaType, "image/jpeg")
        XCTAssertEqual(Data(base64Encoded: photo.dataBase64 ?? ""), jpegA)

        let replace = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, mediaType: "image/jpeg",
            dataBase64: jpegB.base64EncodedString(), idempotencyToken: nil))
        XCTAssertNil(replace?.errorPayload)

        let prior = await MainActor.run {
            fixture.contacts.previousPhotoDataByEffectiveID[Sentinels.guessWhoUUID]
        }
        XCTAssertEqual(prior, jpegA)
        let internalFields = await MainActor.run {
            fixture.contacts.allFields(for: Fixture.janeDoe().contactID)
        }
        XCTAssertTrue(internalFields.contains {
            $0.field == "previousPhoto" && $0.type == .blob
        })

        let visible = await fixture.dispatcher.handle(.contactsListCustomFields(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, limit: nil, cursor: nil))
        guard case .customFieldPage(_, _, let page) = visible else {
            return XCTFail("expected custom-field page")
        }
        XCTAssertFalse(page.items.contains { $0.name == "previousPhoto" })

        let audit = await fixture.audit.entries()
        XCTAssertEqual(audit.filter { $0.action == .editContact }.count, 2)
    }

    func testDeletePreservesCurrentPhotoAndIsIdempotentWhenAbsent() async throws {
        let fixture = await writableFixture()
        let jane = try await janeID(fixture)
        await MainActor.run {
            fixture.contacts.photoDataByLocalID[Sentinels.localID] = jpegA
        }

        let deleted = await fixture.dispatcher.handle(.contactsDeletePhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(deleted?.errorPayload)
        let prior = await MainActor.run {
            fixture.contacts.previousPhotoDataByEffectiveID[Sentinels.guessWhoUUID]
        }
        XCTAssertEqual(prior, jpegA)
        let writesAfterDelete = await MainActor.run { fixture.contacts.photoWriteCount }
        XCTAssertEqual(writesAfterDelete, 1)

        let again = await fixture.dispatcher.handle(.contactsDeletePhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, idempotencyToken: nil))
        XCTAssertNil(again?.errorPayload)
        let finalWrites = await MainActor.run { fixture.contacts.photoWriteCount }
        XCTAssertEqual(finalWrites, 1, "deleting an absent photo is a no-op")
    }

    func testSetRejectsInvalidMismatchedAndOversizedPayloads() async throws {
        let fixture = await writableFixture()
        let jane = try await janeID(fixture)

        let invalid = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, mediaType: "image/jpeg", dataBase64: "%%%",
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(invalid), .invalidParams)

        let mismatch = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, mediaType: "image/png",
            dataBase64: jpegA.base64EncodedString(), idempotencyToken: nil))
        XCTAssertEqual(errorCode(mismatch), .invalidParams)

        let oversized = Data(repeating: 0xff, count: WireEnvironment.maxContactPhotoBytes + 1)
        let tooLarge = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            contactId: jane, mediaType: "image/jpeg",
            dataBase64: oversized.base64EncodedString(), idempotencyToken: nil))
        XCTAssertEqual(errorCode(tooLarge), .tooLarge)
        let writes = await MainActor.run { fixture.contacts.photoWriteCount }
        XCTAssertEqual(writes, 0)
    }

    func testGetEnforcesRawAndEncodedResponseBounds() async throws {
        let fixture = await Fixture.make()
        let jane = try await janeID(fixture)
        var bounded = Data(repeating: 0, count: WireEnvironment.maxContactPhotoBytes)
        bounded.replaceSubrange(0..<3, with: [0xff, 0xd8, 0xff])
        let boundedData = bounded
        await MainActor.run {
            fixture.contacts.photoDataByLocalID[Sentinels.localID] = boundedData
        }
        let response = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        guard case .contactPhoto(_, _, let photo) = response else {
            return XCTFail("the documented maximum must fit the response envelope")
        }
        XCTAssertEqual(photo.byteCount, WireEnvironment.maxContactPhotoBytes)
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(response).count,
            WireEnvironment.maxResponsePayloadBytes)

        var oversized = bounded
        oversized.append(0)
        let oversizedData = oversized
        await MainActor.run {
            fixture.contacts.photoDataByLocalID[Sentinels.localID] = oversizedData
        }
        let rejected = await fixture.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        XCTAssertEqual(errorCode(rejected), .tooLarge)
    }

    func testPermissionAccessModeWriteBudgetAndTypedSaveErrors() async throws {
        let readOnly = await Fixture.make()
        let jane = try await janeID(readOnly)
        let deniedWrite = await readOnly.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(deniedWrite), .readOnly)

        await MainActor.run { readOnly.gates.contactsAuthorized = false }
        let deniedRead = await readOnly.dispatcher.handle(.contactsGetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: jane))
        XCTAssertEqual(errorCode(deniedRead), .permissionDenied)

        let budgeted = await writableFixture(limit: 1)
        let budgetJane = try await janeID(budgeted)
        _ = await budgeted.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: budgetJane,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        let busy = await budgeted.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: budgetJane,
            mediaType: "image/jpeg", dataBase64: jpegB.base64EncodedString(),
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(busy), .busy)

        let failing = await writableFixture()
        let failingJane = try await janeID(failing)
        await MainActor.run {
            failing.contacts.nextContactStoreError = NSError(
                domain: "CNErrorDomain", code: 100, userInfo: [:])
        }
        let permissionFailure = await failing.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: TestMessageID.next(), contactId: failingJane,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        XCTAssertEqual(errorCode(permissionFailure), .permissionDenied)
    }

    func testSetIdempotencyTokenAndIntrinsicIdempotencyAvoidDuplicateWrites() async throws {
        let fixture = await writableFixture()
        let jane = try await janeID(fixture)
        let first = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: "photo-1", contactId: jane,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: "photo-token"))
        XCTAssertNil(first?.errorPayload)
        let replay = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: "photo-2", contactId: jane,
            mediaType: "image/jpeg", dataBase64: jpegB.base64EncodedString(),
            idempotencyToken: "photo-token"))
        XCTAssertNil(replay?.errorPayload)
        var writes = await MainActor.run { fixture.contacts.photoWriteCount }
        XCTAssertEqual(writes, 1)
        let stored = await MainActor.run {
            fixture.contacts.photoDataByLocalID[Sentinels.localID]
        }
        XCTAssertEqual(stored, jpegA, "a replay returns the original outcome")

        _ = await fixture.dispatcher.handle(.contactsSetPhoto(
            helperId: Fixture.helper, messageId: "photo-3", contactId: jane,
            mediaType: "image/jpeg", dataBase64: jpegA.base64EncodedString(),
            idempotencyToken: nil))
        writes = await MainActor.run { fixture.contacts.photoWriteCount }
        XCTAssertEqual(writes, 1, "identical bytes are a no-op without a token too")
    }
}
