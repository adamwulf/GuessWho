import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

final class GroupToolTests: XCTestCase {
    private struct InjectedGroupError: Error {}

    @MainActor
    private func writableFixture(
        writeLimit: Int = 30
    ) -> Fixture {
        let fixture = Fixture.make(writeLimitPerWindow: writeLimit)
        fixture.gates.mcpAccess = .readWrite
        return fixture
    }

    private func groupID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let page) = response else {
            XCTFail("expected group page; got \(String(describing: response))")
            return nil
        }
        return page.items.first?.id
    }

    private func contactIDs(_ fixture: Fixture) async -> [String] {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: nil, favoritesOnly: nil, groupId: nil,
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else {
            XCTFail("expected contact page; got \(String(describing: response))")
            return []
        }
        return page.items.map(\.id)
    }

    func testGroupListIncludesFavoriteAndNeverLeaksLocalID() async {
        let fixture = await writableFixture()
        await MainActor.run {
            _ = fixture.contacts.groupFavoriteLocalIDs.insert("cngroup-local-1")
        }

        let response = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: Fixture.helper, messageId: "list", limit: nil, cursor: nil))
        guard case .groupPage(_, _, let page) = response,
              let group = page.items.first else {
            return XCTFail("expected group page; got \(String(describing: response))")
        }
        XCTAssertEqual(group.name, "Museum Friends")
        XCTAssertTrue(group.isFavorite)
        XCTAssertTrue(group.id.hasPrefix("g-"))
        XCTAssertFalse(response?.wireJSON.contains("CNGroup-LOCAL-1") ?? true)
    }

    func testGroupsListForContactReturnsOnlyMembershipsAndPages() async {
        let fixture = await writableFixture()
        await MainActor.run {
            let second = ContactGroup(localID: "CNGroup-LOCAL-2", name: "Board")
            fixture.contacts.groups.append(second)
            fixture.contacts.membersByGroup[second.localID] = [Fixture.janeDoe()]
        }
        let favoriteResponse = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "favorite-contact",
            kind: nil, favoritesOnly: true, groupId: nil,
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let favorites) = favoriteResponse,
              let resolvedJaneID = favorites.items.first?.id else {
            return XCTFail("expected Jane's public id")
        }
        let first = await fixture.dispatcher.handle(.groupsListForContact(
            helperId: Fixture.helper, messageId: "memberships-1",
            contactId: resolvedJaneID, limit: 1, cursor: nil))
        guard case .groupPage(_, _, let firstPage) = first else {
            return XCTFail("expected first group page")
        }
        XCTAssertEqual(firstPage.items.count, 1)
        XCTAssertNotNil(firstPage.nextCursor)

        let second = await fixture.dispatcher.handle(.groupsListForContact(
            helperId: Fixture.helper, messageId: "memberships-2",
            contactId: resolvedJaneID, limit: 1, cursor: firstPage.nextCursor))
        guard case .groupPage(_, _, let secondPage) = second else {
            return XCTFail("expected second group page")
        }
        XCTAssertEqual(secondPage.items.count, 1)
        XCTAssertNil(secondPage.nextCursor)

        let invalid = await fixture.dispatcher.handle(.groupsListForContact(
            helperId: Fixture.helper, messageId: "memberships-invalid",
            contactId: "not-a-contact", limit: nil, cursor: nil))
        XCTAssertEqual(invalid?.errorPayload?.code, .notFound)
        XCTAssertEqual(invalid?.errorPayload?.message, WireErrorMessage.notFoundContact)
    }

    func testCreateRenameDeleteAndIdempotency() async {
        let fixture = await writableFixture()
        let create = WireRequest.groupsCreate(
            helperId: Fixture.helper, messageId: "create-1",
            name: "  Family  ", idempotencyToken: "create-family")
        let createdResponse = await fixture.dispatcher.handle(create)
        guard case .group(_, _, let created) = createdResponse else {
            return XCTFail("expected created group; got \(String(describing: createdResponse))")
        }
        XCTAssertEqual(created.name, "Family")
        XCTAssertFalse(created.isFavorite)

        let replay = await fixture.dispatcher.handle(.groupsCreate(
            helperId: Fixture.helper, messageId: "create-2",
            name: "Family", idempotencyToken: "create-family"))
        guard case .group(_, let replayMessage, let replayed) = replay else {
            return XCTFail("expected replayed group")
        }
        XCTAssertEqual(replayMessage, "create-2")
        XCTAssertEqual(replayed.id, created.id)
        let createCount = await MainActor.run { fixture.contacts.groupCreateCount }
        XCTAssertEqual(createCount, 1)

        let renamedResponse = await fixture.dispatcher.handle(.groupsRename(
            helperId: Fixture.helper, messageId: "rename",
            groupId: created.id, name: "Relatives", idempotencyToken: nil))
        guard case .group(_, _, let renamed) = renamedResponse else {
            return XCTFail("expected renamed group")
        }
        XCTAssertEqual(renamed.name, "Relatives")
        XCTAssertEqual(renamed.id, created.id)

        let deleted = await fixture.dispatcher.handle(.groupsDelete(
            helperId: Fixture.helper, messageId: "delete",
            groupId: created.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = deleted else {
            return XCTFail("expected delete acknowledgement")
        }
        XCTAssertEqual(message, WireAckMessage.groupDeleted)

        let stale = await fixture.dispatcher.handle(.groupsRename(
            helperId: Fixture.helper, messageId: "stale",
            groupId: created.id, name: "Gone", idempotencyToken: nil))
        XCTAssertEqual(stale?.errorPayload?.code, .notFound)
        XCTAssertEqual(stale?.errorPayload?.message, WireErrorMessage.notFoundGroup)
    }

    func testCreateAndRenameRejectBlankNames() async {
        let fixture = await writableFixture()
        let blankCreate = await fixture.dispatcher.handle(.groupsCreate(
            helperId: Fixture.helper, messageId: "blank-create",
            name: "  \n  ", idempotencyToken: nil))
        XCTAssertEqual(blankCreate?.errorPayload?.code, .invalidParams)
        let createCount = await MainActor.run { fixture.contacts.groupCreateCount }
        XCTAssertEqual(createCount, 0)

        guard let groupId = await groupID(fixture) else { return }
        let blankRename = await fixture.dispatcher.handle(.groupsRename(
            helperId: Fixture.helper, messageId: "blank-rename",
            groupId: groupId, name: "\t", idempotencyToken: nil))
        XCTAssertEqual(blankRename?.errorPayload?.code, .invalidParams)
    }

    func testMembershipAddAndRemoveSucceedAndAuditReadableCounts() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture) else { return }
        let ids = await contactIDs(fixture)
        XCTAssertGreaterThanOrEqual(ids.count, 2)
        let contactId = ids[1]

        let added = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "add-success",
            groupId: groupId, contactIds: [contactId], idempotencyToken: nil))
        guard case .groupMembership(_, _, let addResult) = added else {
            return XCTFail("expected add result; got \(String(describing: added))")
        }
        XCTAssertTrue(addResult.isComplete)
        XCTAssertEqual(addResult.appliedContactIds, [contactId])
        XCTAssertTrue(addResult.failures.isEmpty)

        let removed = await fixture.dispatcher.handle(.groupsRemoveMembers(
            helperId: Fixture.helper, messageId: "remove-success",
            groupId: groupId, contactIds: [contactId], idempotencyToken: nil))
        guard case .groupMembership(_, _, let removeResult) = removed else {
            return XCTFail("expected remove result; got \(String(describing: removed))")
        }
        XCTAssertTrue(removeResult.isComplete)
        XCTAssertEqual(removeResult.appliedContactIds, [contactId])
        XCTAssertTrue(removeResult.failures.isEmpty)

        let entries = await fixture.audit.entries()
        XCTAssertEqual(entries.suffix(2).map(\.action), [
            .addGroupMembers, .removeGroupMembers,
        ])
        XCTAssertEqual(entries.suffix(2).map(\.newValue), [
            "1 contact", "1 contact",
        ])
    }

    func testMembershipAuditUsesResolvedIdentityForPreMintCallerID() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture) else { return }
        let previewID = await MainActor.run {
            fixture.contacts.contacts[1].deterministicGuessWhoID
        }
        await MainActor.run {
            var minted = fixture.contacts.contacts[1]
            minted.urlAddresses.append(LabeledValue(
                label: "",
                value: "guesswho://contact/11111111-2222-4333-8444-555555555555"))
            fixture.contacts.contacts[1] = minted
            fixture.contacts.membersByGroup["CNGroup-LOCAL-1", default: []].append(minted)
        }

        let noOp = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "pre-mint-no-op",
            groupId: groupId, contactIds: [previewID], idempotencyToken: nil))
        guard case .groupMembership(_, _, let noOpResult) = noOp else {
            return XCTFail("expected add result; got \(String(describing: noOp))")
        }
        XCTAssertEqual(noOpResult.appliedContactIds, [previewID])
        let noOpEntries = await fixture.audit.entries()
        XCTAssertTrue(noOpEntries.isEmpty)

        let removed = await fixture.dispatcher.handle(.groupsRemoveMembers(
            helperId: Fixture.helper, messageId: "pre-mint-remove",
            groupId: groupId, contactIds: [previewID], idempotencyToken: nil))
        guard case .groupMembership(_, _, let removeResult) = removed else {
            return XCTFail("expected remove result; got \(String(describing: removed))")
        }
        XCTAssertEqual(removeResult.appliedContactIds, [previewID])
        let entries = await fixture.audit.entries()
        XCTAssertEqual(entries.last?.action, .removeGroupMembers)
        XCTAssertEqual(entries.last?.newValue, "1 contact")
    }

    func testMembershipBatchReportsPartialFailuresWithOpaqueIDs() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture) else { return }
        let ids = await contactIDs(fixture)
        XCTAssertGreaterThanOrEqual(ids.count, 2)
        let failedLocalID = await MainActor.run {
            let failed = fixture.contacts.contacts[1]
            fixture.contacts.membershipFailureLocalIDs.insert(
                failed.contactID.restorationToken.localID)
            return failed.contactID.restorationToken.localID
        }

        let response = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "members",
            groupId: groupId, contactIds: Array(ids.prefix(2)),
            idempotencyToken: "members-once"))
        guard case .groupMembership(_, _, let result) = response else {
            return XCTFail("expected membership result; got \(String(describing: response))")
        }
        XCTAssertEqual(result.appliedContactIds.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.failures.first?.code, .notFound)
        XCTAssertEqual(result.appliedContactIds, [ids[0]])
        XCTAssertEqual(result.failures.first?.contactId, ids[1])
        XCTAssertFalse(response?.wireJSON.contains(failedLocalID) ?? true)
        XCTAssertFalse(response?.agentVisibleText.contains("notFound") ?? true)
        XCTAssertTrue(response?.agentVisibleText.contains(WireErrorMessage.notFoundContact) ?? false)

        _ = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "members-retry",
            groupId: groupId, contactIds: Array(ids.prefix(2)),
            idempotencyToken: "members-once"))
        let writeCount = await MainActor.run {
            fixture.contacts.groupMembershipWriteCount
        }
        XCTAssertEqual(writeCount, 1, "a partial result must replay without reapplying")
    }

    func testMembershipBatchAccountsForPreAndPostMintAliasesOnce() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture) else { return }
        let (previewID, mintedID) = await MainActor.run {
            let preview = fixture.contacts.contacts[1].deterministicGuessWhoID
            var minted = fixture.contacts.contacts[1]
            minted.urlAddresses.append(LabeledValue(
                label: "",
                value: "guesswho://contact/11111111-2222-4333-8444-555555555555"))
            fixture.contacts.contacts[1] = minted
            fixture.contacts.membershipFailureLocalIDs.insert(
                minted.contactID.restorationToken.localID)
            return (preview, "11111111-2222-4333-8444-555555555555")
        }
        XCTAssertNotEqual(previewID, mintedID)

        let partial = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "alias-partial",
            groupId: groupId, contactIds: [previewID, mintedID],
            idempotencyToken: nil))
        guard case .groupMembership(_, _, let partialResult) = partial else {
            return XCTFail("expected partial result; got \(String(describing: partial))")
        }
        XCTAssertTrue(partialResult.appliedContactIds.isEmpty)
        XCTAssertEqual(partialResult.failures.map(\.contactId), [previewID, mintedID])

        await MainActor.run {
            fixture.contacts.membershipFailureLocalIDs.removeAll()
        }
        let success = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "alias-success",
            groupId: groupId, contactIds: [previewID, mintedID],
            idempotencyToken: nil))
        guard case .groupMembership(_, _, let successResult) = success else {
            return XCTFail("expected success result; got \(String(describing: success))")
        }
        XCTAssertEqual(successResult.appliedContactIds, [previewID, mintedID])
        let entries = await fixture.audit.entries()
        XCTAssertEqual(entries.last?.newValue, "1 contact")
    }

    func testMembershipPartialFailuresClassifyPermissionAndWriteErrors() async {
        let cases: [(StoreAuthorizationStatus, any Error, WireErrorCode)] = [
            (StoreAuthorizationStatus.denied, InjectedGroupError(), WireErrorCode.permissionDenied),
            (.authorized, InjectedGroupError(), .writeFailed),
            (.authorized, ContactNotSavedError(), .notFound),
        ]
        for (authorization, error, expectedCode) in cases {
            let fixture = await writableFixture()
            guard let groupId = await groupID(fixture) else { return }
            let ids = await contactIDs(fixture)
            XCTAssertGreaterThanOrEqual(ids.count, 2)
            await MainActor.run {
                let failed = fixture.contacts.contacts[1]
                fixture.contacts.membershipFailureLocalIDs.insert(
                    failed.contactID.restorationToken.localID)
                fixture.contacts.membershipFailureError = error
                fixture.contacts.authorizationStatus = authorization
            }

            let response = await fixture.dispatcher.handle(.groupsAddMembers(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                groupId: groupId, contactIds: [ids[1]], idempotencyToken: nil))
            guard case .groupMembership(_, _, let result) = response else {
                return XCTFail("expected partial result; got \(String(describing: response))")
            }
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertEqual(result.failures.first?.contactId, ids[1])
            XCTAssertEqual(result.failures.first?.code, expectedCode)
        }
    }

    func testMembershipValidatesEveryIDBeforeWriting() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture),
              let valid = await contactIDs(fixture).first else { return }
        let response = await fixture.dispatcher.handle(.groupsRemoveMembers(
            helperId: Fixture.helper, messageId: "invalid-contact",
            groupId: groupId, contactIds: [valid, "not-a-contact"],
            idempotencyToken: nil))
        XCTAssertEqual(response?.errorPayload?.code, .notFound)
        let count = await MainActor.run {
            fixture.contacts.groupMembershipWriteCount
        }
        XCTAssertEqual(count, 0)

        let empty = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "empty",
            groupId: groupId, contactIds: [], idempotencyToken: nil))
        XCTAssertEqual(empty?.errorPayload?.code, .invalidParams)

        let tooMany = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: Fixture.helper, messageId: "too-many",
            groupId: groupId,
            contactIds: (0..<201).map { "id-\($0)" },
            idempotencyToken: nil))
        XCTAssertEqual(tooMany?.errorPayload?.code, .invalidParams)
        let overLimitWrites = await MainActor.run {
            fixture.contacts.groupMembershipWriteCount
        }
        XCTAssertEqual(overLimitWrites, 0)
    }

    func testSetFavoriteResolvesOpaqueIDAndEchoesState() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture) else { return }
        let favorite = await fixture.dispatcher.handle(.groupsSetFavorite(
            helperId: Fixture.helper, messageId: "favorite",
            groupId: groupId, favorite: true, idempotencyToken: nil))
        guard case .group(_, _, let group) = favorite else {
            return XCTFail("expected updated group")
        }
        XCTAssertTrue(group.isFavorite)

        let invalid = await fixture.dispatcher.handle(.groupsSetFavorite(
            helperId: Fixture.helper, messageId: "invalid",
            groupId: "CNGroup-LOCAL-1", favorite: false, idempotencyToken: nil))
        XCTAssertEqual(invalid?.errorPayload?.code, .notFound)
        let setCount = await MainActor.run { fixture.contacts.groupFavoriteSetCount }
        XCTAssertEqual(setCount, 1, "an unresolved id must not touch the favorite key")
    }

    func testPermissionReadOnlyWriteBudgetAndKindGatesApply() async {
        let fixture = await writableFixture(writeLimit: 1)
        await MainActor.run { fixture.gates.contactsAuthorized = false }
        let deniedRead = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: Fixture.helper, messageId: "denied", limit: nil, cursor: nil))
        XCTAssertEqual(deniedRead?.errorPayload?.code, .permissionDenied)

        await MainActor.run {
            fixture.gates.contactsAuthorized = true
            fixture.gates.mcpAccess = .readOnly
        }
        let readOnly = await fixture.dispatcher.handle(.groupsCreate(
            helperId: Fixture.helper, messageId: "readonly",
            name: "Nope", idempotencyToken: nil))
        XCTAssertEqual(readOnly?.errorPayload?.code, .readOnly)

        await MainActor.run { fixture.gates.mcpAccess = .readWrite }
        _ = await fixture.dispatcher.handle(.groupsCreate(
            helperId: Fixture.helper, messageId: "budget-1",
            name: "One", idempotencyToken: nil))
        let busy = await fixture.dispatcher.handle(.groupsCreate(
            helperId: Fixture.helper, messageId: "budget-2",
            name: "Two", idempotencyToken: nil))
        XCTAssertEqual(busy?.errorPayload?.code, .busy)

        guard let existingGroup = await groupID(fixture) else { return }
        let badKind = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: "kind",
            kind: "company", favoritesOnly: nil, groupId: existingGroup,
            limit: nil, cursor: nil))
        XCTAssertEqual(badKind?.errorPayload?.code, .invalidParams)
    }

    func testRuntimePermissionAndStoreErrorsAreTyped() async {
        let fixture = await writableFixture()
        guard let groupId = await groupID(fixture) else { return }
        await MainActor.run {
            fixture.contacts.authorizationStatus = .denied
            fixture.contacts.groupWriteError = InjectedGroupError()
        }
        let denied = await fixture.dispatcher.handle(.groupsRename(
            helperId: Fixture.helper, messageId: "revoked",
            groupId: groupId, name: "New", idempotencyToken: nil))
        XCTAssertEqual(denied?.errorPayload?.code, .permissionDenied)

        await MainActor.run {
            fixture.contacts.authorizationStatus = .authorized
            fixture.contacts.groupWriteError = ContactStoreError.groupNotFound(
                localID: "private")
        }
        let missing = await fixture.dispatcher.handle(.groupsDelete(
            helperId: Fixture.helper, messageId: "gone",
            groupId: groupId, idempotencyToken: nil))
        XCTAssertEqual(missing?.errorPayload?.code, .notFound)
        XCTAssertEqual(missing?.errorPayload?.message, WireErrorMessage.notFoundGroup)
    }

    func testGroupWritesAreAuditedWithoutLocalIdentifiers() async {
        let fixture = await writableFixture()
        let created = await fixture.dispatcher.handle(.groupsCreate(
            helperId: Fixture.helper, messageId: "audit",
            name: "Audited", idempotencyToken: nil))
        guard case .group(_, _, let group) = created else {
            return XCTFail("expected created group")
        }
        let entries = await fixture.audit.entries()
        guard let entry = entries.last else { return XCTFail("missing audit entry") }
        XCTAssertEqual(entry.action, .createGroup)
        XCTAssertEqual(entry.subjectKind, .group)
        XCTAssertEqual(entry.subjectID, group.id)
        XCTAssertTrue(entry.subjectID.hasPrefix("g-"))
        XCTAssertFalse(entry.subjectID.contains("fake-group"))
    }
}
