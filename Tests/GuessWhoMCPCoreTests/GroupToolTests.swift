import XCTest
import GuessWhoSync
import GuessWhoSyncTesting
import GuessWhoMCPCore
import GuessWhoMCPWire

final class GroupToolTests: XCTestCase {
    private struct InjectedGroupError: Error {}

    // MARK: - Production-backed fixture helpers
    //
    // The list / membership / create-rename-delete / favorite /
    // shared-generic-state streams below dispatch against `MCPProductionFixture`,
    // so their assertions reach the REAL `ContactsRepository` (over a
    // `RecordingContactStore` + `InMemoryContactStore`) and the REAL on-disk
    // `FavoritesStore`. Nothing here re-derives group sorting, membership,
    // favorite canonicalization, or audit shape — production code owns all of it.

    @MainActor
    private func writableProductionFixture(
        writeLimit: Int = 30
    ) async throws -> MCPProductionFixture {
        let fixture = try await MCPProductionFixture.make(writeLimitPerWindow: writeLimit)
        fixture.gates.mcpAccess = .readWrite
        return fixture
    }

    /// The wire id of a seeded group, resolved the way an agent would — from
    /// `contacts_list_groups` (which reads the real repository group cache).
    @MainActor
    private func productionGroupID(
        _ fixture: MCPProductionFixture,
        named name: String
    ) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let page) = response else {
            XCTFail("expected group page; got \(String(describing: response))")
            return nil
        }
        return page.items.first { $0.name == name }?.id
    }

    /// The wire id of a seeded contact by display name, read through the real
    /// repository via `contacts_list`.
    @MainActor
    private func productionContactID(
        _ fixture: MCPProductionFixture, named name: String
    ) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            kind: nil, favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else {
            XCTFail("expected contact page; got \(String(describing: response))")
            return nil
        }
        return page.items.first { $0.name == name }?.id
    }

    /// The Contacts local identifier the store issued for a cached group. Used
    /// only for on-disk favorite-key + leak assertions, never sent over the wire.
    @MainActor
    private func localID(
        ofGroupNamed name: String, in fixture: MCPProductionFixture
    ) -> String? {
        fixture.repository.groups.first { $0.name == name }?.localID
    }

    // MARK: - Fake-backed fixture helpers (injected-fault / gate streams)

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

    // MARK: - Group list stream (production-backed)

    @MainActor
    func testGroupListIncludesFavoriteAndNeverLeaksLocalID() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        // Favorite the seeded group by writing straight through the real store;
        // the canonical key is the group's Contacts local identifier, lowercased.
        let groupLocalID = try XCTUnwrap(localID(ofGroupNamed: MCPProductionFixture.groupName, in: fixture))
        try fixture.favoritesStore.set(kind: .group, id: groupLocalID, favorite: true, now: Date())

        let response = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: "list", limit: nil, cursor: nil))
        guard case .groupPage(_, _, let page) = response,
              let group = page.items.first(where: { $0.name == MCPProductionFixture.groupName })
        else {
            return XCTFail("expected group page; got \(String(describing: response))")
        }
        XCTAssertTrue(group.isFavorite)
        XCTAssertTrue(group.id.hasPrefix("g-"))
        XCTAssertFalse(
            response?.wireJSON.contains(groupLocalID) ?? true,
            "the raw Contacts local identifier must never cross the wire")
    }

    @MainActor
    func testGroupsListForContactReturnsOnlyMembershipsAndPages() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        // Ada already belongs to the seeded group; a second membership makes a
        // limit-1 page split observable.
        try await fixture.seedGroup(named: "Board", memberLocalIDs: [MCPProductionFixture.adaLocalID])

        // Ada is reconciled, so her wire id is her known GuessWho UUID.
        let resolvedAdaID = MCPProductionFixture.adaGuessWhoID
        let first = await fixture.dispatcher.handle(.groupsListForContact(
            helperId: MCPProductionFixture.helper, messageId: "memberships-1",
            contactId: resolvedAdaID, limit: 1, cursor: nil))
        guard case .groupPage(_, _, let firstPage) = first else {
            return XCTFail("expected first group page")
        }
        XCTAssertEqual(firstPage.items.count, 1)
        XCTAssertNotNil(firstPage.nextCursor)

        let second = await fixture.dispatcher.handle(.groupsListForContact(
            helperId: MCPProductionFixture.helper, messageId: "memberships-2",
            contactId: resolvedAdaID, limit: 1, cursor: firstPage.nextCursor))
        guard case .groupPage(_, _, let secondPage) = second else {
            return XCTFail("expected second group page")
        }
        XCTAssertEqual(secondPage.items.count, 1)
        XCTAssertNil(secondPage.nextCursor)
        guard let firstGroup = firstPage.items.first,
              let secondGroup = secondPage.items.first
        else { return XCTFail("expected one group on each page") }
        // Exactly Ada's two memberships resolve, and only those.
        XCTAssertEqual(
            Set([firstGroup.name, secondGroup.name]),
            [MCPProductionFixture.groupName, "Board"])

        let invalid = await fixture.dispatcher.handle(.groupsListForContact(
            helperId: MCPProductionFixture.helper, messageId: "memberships-invalid",
            contactId: "not-a-contact", limit: nil, cursor: nil))
        XCTAssertEqual(invalid?.errorPayload?.code, .notFound)
        XCTAssertEqual(invalid?.errorPayload?.message, WireErrorMessage.notFoundContact)
    }

    // MARK: - Create / rename / delete stream (production-backed)

    @MainActor
    func testCreateRenameDeleteAndIdempotency() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let create = WireRequest.groupsCreate(
            helperId: MCPProductionFixture.helper, messageId: "create-1",
            name: "  Family  ", idempotencyToken: "create-family")
        let createdResponse = await fixture.dispatcher.handle(create)
        guard case .group(_, _, let created) = createdResponse else {
            return XCTFail("expected created group; got \(String(describing: createdResponse))")
        }
        XCTAssertEqual(created.name, "Family")
        XCTAssertFalse(created.isFavorite)

        let replay = await fixture.dispatcher.handle(.groupsCreate(
            helperId: MCPProductionFixture.helper, messageId: "create-2",
            name: "Family", idempotencyToken: "create-family"))
        guard case .group(_, let replayMessage, let replayed) = replay else {
            return XCTFail("expected replayed group")
        }
        XCTAssertEqual(replayMessage, "create-2")
        XCTAssertEqual(replayed.id, created.id)
        // The idempotent replay must NOT have created a second group in the store.
        let afterCreate = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: "after-create",
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let createdGroups) = afterCreate else {
            return XCTFail("expected group page")
        }
        XCTAssertEqual(createdGroups.items.filter { $0.name == "Family" }.count, 1)
        XCTAssertEqual(createdGroups.items.filter { $0.id == created.id }.count, 1)

        let renamedResponse = await fixture.dispatcher.handle(.groupsRename(
            helperId: MCPProductionFixture.helper, messageId: "rename",
            groupId: created.id, name: "Relatives", idempotencyToken: nil))
        guard case .group(_, _, let renamed) = renamedResponse else {
            return XCTFail("expected renamed group")
        }
        XCTAssertEqual(renamed.name, "Relatives")
        XCTAssertEqual(renamed.id, created.id)

        let deleted = await fixture.dispatcher.handle(.groupsDelete(
            helperId: MCPProductionFixture.helper, messageId: "delete",
            groupId: created.id, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = deleted else {
            return XCTFail("expected delete acknowledgement")
        }
        XCTAssertEqual(message, WireAckMessage.groupDeleted)

        let auditEntries = await fixture.audit.entries()
        XCTAssertEqual(auditEntries.map(\.action), [
            .createGroup, .renameGroup, .deleteGroup,
        ])
        XCTAssertEqual(auditEntries.map(\.subjectKind), [.group, .group, .group])
        XCTAssertEqual(auditEntries.map(\.subjectID), [created.id, created.id, created.id])
        XCTAssertEqual(auditEntries.map(\.priorValue), [nil, "Family", "Relatives"])
        XCTAssertEqual(auditEntries.map(\.newValue), ["Family", "Relatives", nil])

        let stale = await fixture.dispatcher.handle(.groupsRename(
            helperId: MCPProductionFixture.helper, messageId: "stale",
            groupId: created.id, name: "Gone", idempotencyToken: nil))
        XCTAssertEqual(stale?.errorPayload?.code, .notFound)
        XCTAssertEqual(stale?.errorPayload?.message, WireErrorMessage.notFoundGroup)
    }

    @MainActor
    func testCreateAndRenameRejectBlankNames() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let blankCreate = await fixture.dispatcher.handle(.groupsCreate(
            helperId: MCPProductionFixture.helper, messageId: "blank-create",
            name: "  \n  ", idempotencyToken: nil))
        XCTAssertEqual(blankCreate?.errorPayload?.code, .invalidParams)
        // No group was created: only the seeded group remains.
        let afterBlank = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: "after-blank",
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let groups) = afterBlank else {
            return XCTFail("expected group page")
        }
        XCTAssertEqual(groups.items.map(\.name), [MCPProductionFixture.groupName])

        guard let groupId = groups.items.first?.id else { return }
        let blankRename = await fixture.dispatcher.handle(.groupsRename(
            helperId: MCPProductionFixture.helper, messageId: "blank-rename",
            groupId: groupId, name: "\t", idempotencyToken: nil))
        XCTAssertEqual(blankRename?.errorPayload?.code, .invalidParams)
    }

    // MARK: - Membership stream (production-backed)

    @MainActor
    func testMembershipAddAndRemoveSucceedAndAuditReadableCounts() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let resolvedGroupID = await productionGroupID(fixture, named: MCPProductionFixture.groupName)
        let groupId = try XCTUnwrap(resolvedGroupID)
        let pioneersLocalID = try XCTUnwrap(localID(ofGroupNamed: MCPProductionFixture.groupName, in: fixture))
        // Add a contact who is NOT already a member (Ada is the seeded member).
        let resolvedContactID = await productionContactID(fixture, named: "Blaise Pascal")
        let contactId = try XCTUnwrap(resolvedContactID)

        let added = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: MCPProductionFixture.helper, messageId: "add-success",
            groupId: groupId, contactIds: [contactId], idempotencyToken: nil))
        guard case .groupMembership(_, _, let addResult) = added else {
            return XCTFail("expected add result; got \(String(describing: added))")
        }
        XCTAssertTrue(addResult.isComplete)
        XCTAssertEqual(addResult.appliedContactIds, [contactId])
        XCTAssertTrue(addResult.failures.isEmpty)
        // The membership really landed in the store.
        let membersAfterAdd = await fixture.repository.members(ofGroup: pioneersLocalID)
        XCTAssertTrue(membersAfterAdd.contains { $0.localID == MCPProductionFixture.blaiseLocalID })

        let removed = await fixture.dispatcher.handle(.groupsRemoveMembers(
            helperId: MCPProductionFixture.helper, messageId: "remove-success",
            groupId: groupId, contactIds: [contactId], idempotencyToken: nil))
        guard case .groupMembership(_, _, let removeResult) = removed else {
            return XCTFail("expected remove result; got \(String(describing: removed))")
        }
        XCTAssertTrue(removeResult.isComplete)
        XCTAssertEqual(removeResult.appliedContactIds, [contactId])
        XCTAssertTrue(removeResult.failures.isEmpty)
        let membersAfterRemove = await fixture.repository.members(ofGroup: pioneersLocalID)
        XCTAssertFalse(membersAfterRemove.contains { $0.localID == MCPProductionFixture.blaiseLocalID })

        let entries = await fixture.audit.entries()
        XCTAssertEqual(entries.suffix(2).map(\.action), [
            .addGroupMembers, .removeGroupMembers,
        ])
        XCTAssertEqual(entries.suffix(2).map(\.newValue), [
            "1 contact", "1 contact",
        ])
    }

    @MainActor
    func testMembershipValidatesEveryIDBeforeWriting() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let resolvedGroupID = await productionGroupID(fixture, named: MCPProductionFixture.groupName)
        let groupId = try XCTUnwrap(resolvedGroupID)
        let pioneersLocalID = try XCTUnwrap(localID(ofGroupNamed: MCPProductionFixture.groupName, in: fixture))
        // Ada is a real member; pairing her with an invalid id proves the whole
        // batch is rejected before any write touches the store.
        let membersBefore = await fixture.repository.members(ofGroup: pioneersLocalID)
            .map(\.localID).sorted()
        let response = await fixture.dispatcher.handle(.groupsRemoveMembers(
            helperId: MCPProductionFixture.helper, messageId: "invalid-contact",
            groupId: groupId, contactIds: [MCPProductionFixture.adaGuessWhoID, "not-a-contact"],
            idempotencyToken: nil))
        XCTAssertEqual(response?.errorPayload?.code, .notFound)
        let membersAfterInvalid = await fixture.repository.members(ofGroup: pioneersLocalID)
            .map(\.localID).sorted()
        XCTAssertEqual(membersAfterInvalid, membersBefore, "a rejected batch must not write")

        let empty = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: MCPProductionFixture.helper, messageId: "empty",
            groupId: groupId, contactIds: [], idempotencyToken: nil))
        XCTAssertEqual(empty?.errorPayload?.code, .invalidParams)

        let tooMany = await fixture.dispatcher.handle(.groupsAddMembers(
            helperId: MCPProductionFixture.helper, messageId: "too-many",
            groupId: groupId,
            contactIds: (0..<201).map { "id-\($0)" },
            idempotencyToken: nil))
        XCTAssertEqual(tooMany?.errorPayload?.code, .invalidParams)
        let membersAfterTooMany = await fixture.repository.members(ofGroup: pioneersLocalID)
            .map(\.localID).sorted()
        XCTAssertEqual(membersAfterTooMany, membersBefore, "an over-limit batch must not write")
    }

    // MARK: - Group favorite stream (production-backed)

    @MainActor
    func testSetFavoriteResolvesOpaqueIDAndEchoesState() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let resolvedGroupID = await productionGroupID(fixture, named: MCPProductionFixture.groupName)
        let groupId = try XCTUnwrap(resolvedGroupID)
        let pioneersLocalID = try XCTUnwrap(localID(ofGroupNamed: MCPProductionFixture.groupName, in: fixture))

        let favorite = await fixture.dispatcher.handle(.groupsSetFavorite(
            helperId: MCPProductionFixture.helper, messageId: "favorite",
            groupId: groupId, favorite: true, idempotencyToken: nil))
        guard case .group(_, _, let group) = favorite else {
            return XCTFail("expected updated group")
        }
        XCTAssertTrue(group.isFavorite)
        // Durable on disk under the group's canonical (lowercased) local id.
        XCTAssertTrue(try fixture.favoritesStore.loadAll().contains {
            $0.kind == .group && $0.id == pioneersLocalID.lowercased()
        })

        var entries = await fixture.audit.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.last?.action, .setFavorite)
        XCTAssertEqual(entries.last?.subjectKind, .group)
        XCTAssertEqual(entries.last?.subjectID, groupId)
        XCTAssertEqual(entries.last?.priorValue, "false")
        XCTAssertEqual(entries.last?.newValue, "true")

        let noOp = await fixture.dispatcher.handle(.groupsSetFavorite(
            helperId: MCPProductionFixture.helper, messageId: "favorite-no-op",
            groupId: groupId, favorite: true, idempotencyToken: nil))
        guard case .group(_, _, let unchanged) = noOp else {
            return XCTFail("expected unchanged group")
        }
        XCTAssertTrue(unchanged.isFavorite)
        entries = await fixture.audit.entries()
        XCTAssertEqual(entries.count, 1, "an idempotent favorite write must not add an audit entry")

        let unfavorite = await fixture.dispatcher.handle(.groupsSetFavorite(
            helperId: MCPProductionFixture.helper, messageId: "unfavorite",
            groupId: groupId, favorite: false, idempotencyToken: nil))
        guard case .group(_, _, let cleared) = unfavorite else {
            return XCTFail("expected updated group")
        }
        XCTAssertFalse(cleared.isFavorite)
        entries = await fixture.audit.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.action, .setFavorite)
        XCTAssertEqual(entries.last?.priorValue, "true")
        XCTAssertEqual(entries.last?.newValue, "false")
        XCTAssertFalse(try fixture.favoritesStore.loadAll().contains { $0.kind == .group })

        // An unresolved id resolves to no group, so it must not touch the file.
        let favoritesBeforeInvalid = try fixture.favoritesStore.loadAll()
        let invalid = await fixture.dispatcher.handle(.groupsSetFavorite(
            helperId: MCPProductionFixture.helper, messageId: "invalid",
            groupId: "not-a-group", favorite: false, idempotencyToken: nil))
        XCTAssertEqual(invalid?.errorPayload?.code, .notFound)
        XCTAssertEqual(
            try fixture.favoritesStore.loadAll(), favoritesBeforeInvalid,
            "an unresolved id must not touch the favorites file")
    }

    @MainActor
    func testGroupSpecificAndGenericFavoritesShareState() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let resolvedGroupID = await productionGroupID(fixture, named: MCPProductionFixture.groupName)
        let groupId = try XCTUnwrap(resolvedGroupID)

        guard case .group(_, _, let favorited) = await fixture.dispatcher.handle(
            .groupsSetFavorite(
                helperId: MCPProductionFixture.helper, messageId: "group-favorite",
                groupId: groupId, favorite: true, idempotencyToken: nil)
        ) else {
            return XCTFail("expected group favorite result")
        }
        XCTAssertTrue(favorited.isFavorite)

        let genericList = await fixture.dispatcher.handle(.favoritesList(
            helperId: MCPProductionFixture.helper, messageId: "generic-list",
            limit: nil, cursor: nil))
        guard case .favoritePage(_, _, let favorites) = genericList else {
            return XCTFail("expected generic favorites page")
        }
        XCTAssertTrue(favorites.items.contains {
            $0.kind == .group && $0.id == groupId && $0.isAvailable
        })

        guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "generic-clear",
            kind: .group, id: groupId, favorite: false,
            idempotencyToken: nil)) else {
            return XCTFail("expected generic favorite acknowledgement")
        }
        let groupList = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: "group-list",
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let groups) = groupList else {
            return XCTFail("expected group page")
        }
        XCTAssertEqual(groups.items.first { $0.id == groupId }?.isFavorite, false)

        guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "generic-set",
            kind: .group, id: groupId, favorite: true,
            idempotencyToken: nil)) else {
            return XCTFail("expected generic favorite acknowledgement")
        }
        let favoritedGroupList = await fixture.dispatcher.handle(.contactsListGroups(
            helperId: MCPProductionFixture.helper, messageId: "favorited-group-list",
            limit: nil, cursor: nil))
        guard case .groupPage(_, _, let favoritedGroups) = favoritedGroupList else {
            return XCTFail("expected group page")
        }
        XCTAssertEqual(favoritedGroups.items.first { $0.id == groupId }?.isFavorite, true)

        guard case .acknowledged = await fixture.dispatcher.handle(.groupsDelete(
            helperId: MCPProductionFixture.helper, messageId: "delete-group",
            groupId: groupId, idempotencyToken: nil)) else {
            return XCTFail("expected group delete acknowledgement")
        }
        let afterDelete = await fixture.dispatcher.handle(.favoritesList(
            helperId: MCPProductionFixture.helper, messageId: "favorites-after-delete",
            limit: nil, cursor: nil))
        guard case .favoritePage(_, _, let remaining) = afterDelete else {
            return XCTFail("expected generic favorites page")
        }
        XCTAssertFalse(remaining.items.contains { $0.kind == .group && $0.id == groupId })
    }

    @MainActor
    func testGroupWritesAreAuditedWithoutLocalIdentifiers() async throws {
        let fixture = try await writableProductionFixture()
        defer { fixture.cleanUp() }
        let created = await fixture.dispatcher.handle(.groupsCreate(
            helperId: MCPProductionFixture.helper, messageId: "audit",
            name: "Audited", idempotencyToken: nil))
        guard case .group(_, _, let group) = created else {
            return XCTFail("expected created group")
        }
        // The store issued a real local identifier; it must never surface in the
        // audit trail — only the opaque `g-` wire id may.
        let createdLocalID = try XCTUnwrap(localID(ofGroupNamed: "Audited", in: fixture))
        let entries = await fixture.audit.entries()
        guard let entry = entries.last else { return XCTFail("missing audit entry") }
        XCTAssertEqual(entry.action, .createGroup)
        XCTAssertEqual(entry.subjectKind, .group)
        XCTAssertEqual(entry.subjectID, group.id)
        XCTAssertTrue(entry.subjectID.hasPrefix("g-"))
        XCTAssertFalse(entry.subjectID.contains(createdLocalID))
    }

    // MARK: - Injected-fault / identity-simulation streams (fake-backed)
    //
    // These stay on `Fixture` deliberately: each depends on a fault or identity
    // race the OS-boundary `RecordingContactStore` does not expose —
    // per-contact membership failures, pre/post-mint alias simulation, injected
    // authorization / write errors. They are the sanctioned "OS-boundary fakes
    // for injected faults" carve-out, not re-implementations of store rules.

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

    // MARK: - Gate / budget stream (fake-backed dispatcher gate)

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
}
