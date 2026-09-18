import Foundation
import XCTest
import MCP
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

@MainActor
final class FolderToolTests: XCTestCase {
    private func call(
        _ fixture: MCPProductionFixture, _ tool: MCPTool,
        _ arguments: [String: Value] = [:], helper: String? = nil
    ) async throws -> WireResponse {
        let request = try WireRequest.create(
            helperId: helper ?? MCPProductionFixture.helper, messageId: TestMessageID.next(),
            parameters: MCP.CallTool.Parameters(name: tool.rawValue, arguments: arguments))
        let response = await fixture.dispatcher.handle(request)
        return try XCTUnwrap(response)
    }

    private func fixture() async throws -> MCPProductionFixture {
        let fixture = try await MCPProductionFixture.make(writeLimitPerWindow: 100)
        fixture.gates.mcpAccess = .readWrite
        return fixture
    }

    private func folder(_ response: WireResponse) throws -> WireFolder {
        guard case .folder(_, _, let folder) = response else {
            XCTFail("Expected a folder, got \(response)")
            throw CocoaError(.coderInvalidValue)
        }
        return folder
    }

    private func members(_ response: WireResponse) throws -> WireFolderMemberPage {
        guard case .folderMemberPage(_, _, let page) = response else {
            XCTFail("Expected folder members, got \(response)")
            throw CocoaError(.coderInvalidValue)
        }
        return page
    }

    private func groups(_ fixture: MCPProductionFixture) async throws -> [WireGroup] {
        let response = try await call(fixture, .contactsListGroups)
        guard case .groupPage(_, _, let page) = response else {
            throw CocoaError(.coderInvalidValue)
        }
        return page.items
    }

    func testCreateRenameMoveDeleteAndAudit() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let root = try folder(await call(f, .foldersCreate, ["name": "Family"]))
        let child = try folder(await call(f, .foldersCreate, [
            "name": "  Activities  ", "parentFolderId": .string(root.id),
        ]))
        XCTAssertEqual(child.name, "Activities")
        XCTAssertEqual(child.parentFolderId, root.id)
        XCTAssertNotNil(UUID(uuidString: child.id))
        XCTAssertEqual(child.id, child.id.lowercased())
        let renamed = try folder(await call(f, .foldersRename, [
            "folderId": .string(child.id), "name": "Clubs",
        ]))
        XCTAssertEqual(renamed.name, "Clubs")
        XCTAssertEqual(renamed.parentFolderId, root.id)
        let moved = try folder(await call(f, .foldersMove, ["folderId": .string(child.id)]))
        XCTAssertNil(moved.parentFolderId)
        _ = try await call(f, .foldersMove, ["folderId": .string(child.id), "parentFolderId": .string(root.id)])
        let deleted = try await call(f, .foldersDelete, ["folderId": .string(root.id)])
        guard case .acknowledged = deleted else { return XCTFail("Expected deletion acknowledgement") }
        XCTAssertNil(f.repository.groupFolderTree.folders[root.id])
        XCTAssertNil(f.repository.groupFolderTree.folders[child.id]?.parentFolderID)
        let audit = await f.storedAuditEntries()
        XCTAssertEqual(audit.map(\.action), [.createFolder, .createFolder, .renameFolder, .moveFolder, .moveFolder, .deleteFolder])
        XCTAssertTrue(audit.allSatisfy { $0.subjectKind == .folder })
    }

    func testFolderListPagesInTreeOrder() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let root = try folder(await call(f, .foldersCreate, ["name": "A"]))
        let nested = try folder(await call(f, .foldersCreate, ["name": "Z", "parentFolderId": .string(root.id)]))
        let last = try folder(await call(f, .foldersCreate, ["name": "B"]))
        var ids: [String] = []
        var cursor: String?
        repeat {
            var args: [String: Value] = ["limit": 1]
            if let cursor { args["cursor"] = .string(cursor) }
            guard case .folderPage(_, _, let page) = try await call(f, .foldersList, args) else {
                return XCTFail("Expected a folder page")
            }
            ids.append(contentsOf: page.items.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(ids, [root.id, nested.id, last.id])
    }

    func testGroupMoveAndNullableDestinationsKeepMembersAndFavorite() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let root = try folder(await call(f, .foldersCreate, ["name": "Family", "parentFolderId": .null]))
        let initialGroups = try await groups(f)
        let group = try XCTUnwrap(initialGroups.first)
        let favorited = try await call(f, .groupsSetFavorite, ["groupId": .string(group.id), "favorite": true])
        guard case .group(_, _, let favoriteGroup) = favorited else {
            return XCTFail("Expected favorite group, got \(favorited)")
        }
        XCTAssertTrue(favoriteGroup.isFavorite)
        for destination: Value in [.string(root.id), .null, .string(root.id)] {
            guard case .group(_, _, let moved) = try await call(f, .groupsMove, [
                "groupId": .string(group.id), "parentFolderId": destination,
            ]) else { return XCTFail("Expected moved group") }
            XCTAssertEqual(moved.parentFolderId, destination.stringValue)
            XCTAssertTrue(moved.isFavorite)
            let listed = try await groups(f)
            XCTAssertEqual(listed.first?.parentFolderId, destination.stringValue)
        }
        let page = try members(await call(f, .foldersListMembers, ["folderId": .string(root.id)]))
        XCTAssertEqual(page.items.map(\.id), [MCPProductionFixture.adaGuessWhoID])
        XCTAssertFalse(page.partial)
        XCTAssertTrue(page.unloadedGroupIds.isEmpty)
        _ = try await call(f, .groupsMove, ["groupId": .string(group.id)])
        let topLevelGroups = try await groups(f)
        XCTAssertNil(topLevelGroups.first?.parentFolderId)
        let empty = try members(await call(f, .foldersListMembers, ["folderId": .string(root.id)]))
        XCTAssertTrue(empty.items.isEmpty)
    }

    private func populatedFolder(_ f: MCPProductionFixture) async throws -> String {
        let root = try folder(await call(f, .foldersCreate, ["name": "All groups"]))
        let nested = try folder(await call(f, .foldersCreate, ["name": "Nested", "parentFolderId": .string(root.id)]))
        let extra = try await f.seedGroup(named: "Other", memberLocalIDs: [
            MCPProductionFixture.adaLocalID, MCPProductionFixture.blaiseLocalID,
        ])
        for group in f.repository.groups {
            try await f.repository.moveGroup(group, toFolder: group == extra ? nested.id : root.id)
        }
        return root.id
    }

    func testMemberPagingDeduplicatesBeforePaging() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let id = try await populatedFolder(f)
        let all = try members(await call(f, .foldersListMembers, ["folderId": .string(id)]))
        let first = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1]))
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1, "cursor": .string(cursor)]))
        XCTAssertEqual(first.items.map(\.id) + second.items.map(\.id), all.items.map(\.id))
        XCTAssertEqual(Set(all.items.map(\.id)).count, 2)
        XCTAssertNil(second.nextCursor)
    }

    /// Unlike `populatedFolder`, these groups have disjoint members. Losing or
    /// recovering the first group shifts every later member's page offset.
    private func folderWithDisjointGroups(_ f: MCPProductionFixture) async throws -> (String, ContactGroup) {
        let firstGroup = try XCTUnwrap(f.repository.groups.first)
        _ = try await f.seedGroup(named: "ZZZ other", memberLocalIDs: [
            MCPProductionFixture.blaiseLocalID, MCPProductionFixture.orgLocalID,
        ])
        let root = try folder(await call(f, .foldersCreate, ["name": "All groups"]))
        for group in f.repository.groups {
            try await f.repository.moveGroup(group, toFolder: root.id)
        }
        return (root.id, firstGroup)
    }

    func testMemberCursorRejectsNewReadFailureWithoutRevisionChange() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let (id, group) = try await folderWithDisjointGroups(f)
        let first = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1]))
        XCTAssertEqual(first.items.map(\.id), [MCPProductionFixture.adaGuessWhoID])
        let cursor = try XCTUnwrap(first.nextCursor)
        let revisions = f.repository.memberRevisions

        await f.store.failMemberRead(forGroup: group.localID)
        let response = try await call(f, .foldersListMembers, [
            "folderId": .string(id), "limit": 1, "cursor": .string(cursor),
        ])

        XCTAssertEqual(f.repository.memberRevisions, revisions)
        XCTAssertEqual(response.errorPayload?.code, .invalidParams)
        XCTAssertTrue(response.errorPayload?.message.contains("cursor") == true)
        // Restarting still returns the available members, labeled partial.
        let restarted = try members(await call(f, .foldersListMembers, ["folderId": .string(id)]))
        XCTAssertTrue(restarted.partial)
        XCTAssertEqual(restarted.items.count, 2)
    }

    func testMemberCursorRejectsRecoveredReadWithoutRevisionChange() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let (id, group) = try await folderWithDisjointGroups(f)
        await f.store.failMemberRead(forGroup: group.localID)
        let first = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1]))
        XCTAssertTrue(first.partial)
        let cursor = try XCTUnwrap(first.nextCursor)
        let revisions = f.repository.memberRevisions

        await f.store.restoreMemberRead(forGroup: group.localID)
        let response = try await call(f, .foldersListMembers, [
            "folderId": .string(id), "limit": 1, "cursor": .string(cursor),
        ])

        XCTAssertEqual(f.repository.memberRevisions, revisions)
        XCTAssertEqual(response.errorPayload?.code, .invalidParams)
        XCTAssertTrue(response.errorPayload?.message.contains("cursor") == true)
        let restarted = try members(await call(f, .foldersListMembers, ["folderId": .string(id)]))
        XCTAssertFalse(restarted.partial)
        XCTAssertEqual(restarted.items.count, 3)
    }

    func testMemberCursorContinuesAnUnchangedPartialResult() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let (id, group) = try await folderWithDisjointGroups(f)
        await f.store.failMemberRead(forGroup: group.localID)
        let all = try members(await call(f, .foldersListMembers, ["folderId": .string(id)]))
        let first = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1]))
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try members(await call(f, .foldersListMembers, [
            "folderId": .string(id), "limit": 1, "cursor": .string(cursor),
        ]))

        XCTAssertTrue(first.partial)
        XCTAssertTrue(second.partial)
        XCTAssertEqual(first.unloadedGroupIds, second.unloadedGroupIds)
        XCTAssertEqual(first.items.map(\.id) + second.items.map(\.id), all.items.map(\.id))
        XCTAssertNil(second.nextCursor)
    }

    func testMemberCursorRejectsChangedMembershipContactsAndHierarchy() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let id = try await populatedFolder(f)
        for change in 0..<3 {
            let first = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1]))
            let cursor = try XCTUnwrap(first.nextCursor)
            switch change {
            case 0:
                let group = try XCTUnwrap(f.repository.groups.first)
                let contact = try XCTUnwrap(f.contact(localID: MCPProductionFixture.orgLocalID))
                try await f.repository.addContacts([contact], toGroup: group)
            case 1:
                await f.reload()
            default:
                _ = try await call(f, .foldersCreate, ["name": "New folder"])
            }
            let response = try await call(f, .foldersListMembers, [
                "folderId": .string(id), "cursor": .string(cursor),
            ])
            XCTAssertEqual(response.errorPayload?.code, .invalidParams)
            XCTAssertTrue(response.errorPayload?.message.contains("cursor") == true)
        }
    }

    func testMemberCursorRejectsWrongFolderAndMalformedCursor() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let id = try await populatedFolder(f)
        let other = try folder(await call(f, .foldersCreate, ["name": "Other folder"]))
        let first = try members(await call(f, .foldersListMembers, ["folderId": .string(id), "limit": 1]))
        let cursor = try XCTUnwrap(first.nextCursor)
        for badCursor in [cursor, "o1", "not a cursor"] {
            let response = try await call(f, .foldersListMembers, [
                "folderId": .string(other.id), "cursor": .string(badCursor),
            ])
            XCTAssertEqual(response.errorPayload?.code, .invalidParams)
        }
    }

    func testPartialMembersNamesUnloadedGroups() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let id = try await populatedFolder(f)
        let group = try XCTUnwrap(f.repository.groups.first { $0.name == MCPProductionFixture.groupName })
        let listedGroups = try await groups(f)
        let wireGroup = try XCTUnwrap(listedGroups.first { $0.name == group.name })
        await f.store.failMemberRead(forGroup: group.localID)
        let page = try members(await call(f, .foldersListMembers, ["folderId": .string(id)]))
        XCTAssertTrue(page.partial)
        XCTAssertEqual(page.unloadedGroupIds, [wireGroup.id])
        XCTAssertEqual(page.items.count, 2)
    }

    func testUnavailablePlacementIsReportedAsPartialOnTheWire() async throws {
        try await assertUnavailableGroupRecordIsPartial(damageIdentity: false)
    }

    func testMalformedIdentityWithValidPlacementIsReportedAsPartialOnTheWire() async throws {
        try await assertUnavailableGroupRecordIsPartial(damageIdentity: true)
    }

    private func assertUnavailableGroupRecordIsPartial(damageIdentity: Bool) async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let (folderID, hidden) = try await folderWithDisjointGroups(f)
        let identity = try XCTUnwrap(try f.sync.allGroupIdentities().first { $0.name == GroupIdentity.normalizedName(hidden.name) })
        let key = SidecarKey(kind: .group, id: identity.id)
        let original = try XCTUnwrap(try f.sidecars.read(key))
        var fields = original.fields
        if damageIdentity {
            let cell = try XCTUnwrap(fields[GuessWhoSync.groupIdentityCellKey])
            guard case .object(var inner) = cell.value else { return XCTFail("Expected identity object") }
            inner["value"] = .string("{invalid JSON")
            fields[GuessWhoSync.groupIdentityCellKey] = SidecarCell(
                value: .object(inner), modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy)
        } else {
            fields["parentFolder"] = SidecarCell(value: .string("future format"), modifiedAt: Date(), modifiedBy: "B")
        }
        try f.sidecars.write(SidecarEnvelope(entityID: key.id, fields: fields), at: key)

        let partial = try members(await call(f, .foldersListMembers, ["folderId": .string(folderID)]))
        XCTAssertTrue(partial.partial)
        XCTAssertEqual(partial.items.count, 2)
        // The unreadable placement cannot be assigned to this folder reliably.
        XCTAssertTrue(partial.unloadedGroupIds.isEmpty)

        try f.sidecars.write(original, at: key)
        let recovered = try members(await call(f, .foldersListMembers, ["folderId": .string(folderID)]))
        XCTAssertFalse(recovered.partial)
        XCTAssertEqual(recovered.items.count, 3)
    }

    func testFolderIDsRejectedEverywhereAGroupIsRequired() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let folder = try folder(await call(f, .foldersCreate, ["name": "Family"]))
        for tool in [MCPTool.groupsAddMembers, .groupsRemoveMembers, .groupsRename,
                     .groupsDelete, .groupsSetFavorite, .contactsList, .groupsMove] {
            let response = try await call(f, tool, [
                "groupId": .string(folder.id), "contactIds": [.string(MCPProductionFixture.adaGuessWhoID)],
                "name": "New name", "favorite": true,
            ])
            XCTAssertEqual(response.errorPayload?.code, .invalidParams, tool.rawValue)
            // The message has to make sense for EVERY tool in this loop — a
            // rename or a move is not about members — so it names the mistake
            // (a folder id where a group id belongs) first.
            XCTAssertTrue(
                response.errorPayload?.message.contains("That is a folder id, and this needs a group id") == true,
                tool.rawValue)
        }
        XCTAssertNotNil(f.repository.groupFolderTree.folders[folder.id])
        XCTAssertEqual(f.repository.groups.count, 1)
    }

    func testCreateRetryAcrossSessionsReturnsSameFolder() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let args: [String: Value] = ["name": "Family", "idempotencyToken": "folder-once"]
        let first = try folder(await call(f, .foldersCreate, args))
        let replay = try folder(await call(f, .foldersCreate, args))
        let newSession = try folder(await call(f, .foldersCreate, args, helper: RequestOrigin.mcp.makeHelperId()))
        XCTAssertEqual(first.id, replay.id)
        XCTAssertEqual(first.id, newSession.id)
        XCTAssertEqual(f.repository.groupFolderTree.folders.count, 1)
        let audit = await f.storedAuditEntries()
        XCTAssertEqual(audit.filter { $0.action == .createFolder }.count, 1)
    }

    func testValidationErrorsAndDeletedMembers() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let root = try folder(await call(f, .foldersCreate, ["name": "Family"]))
        let child = try folder(await call(f, .foldersCreate, ["name": "Child", "parentFolderId": .string(root.id)]))
        for destination in [root.id, child.id] {
            let response = try await call(f, .foldersMove, ["folderId": .string(root.id), "parentFolderId": .string(destination)])
            XCTAssertEqual(response.errorPayload?.code, .invalidParams)
            XCTAssertTrue(response.errorPayload?.message.contains("into itself") == true)
        }
        let emptyName = try await call(f, .foldersCreate, ["name": "  "])
        XCTAssertEqual(emptyName.errorPayload?.code, .invalidParams)
        let invalid = try await call(f, .foldersMove, ["folderId": .string(root.id), "parentFolderId": "not-a-folder"])
        XCTAssertEqual(invalid.errorPayload?.code, .invalidParams)
        let missing = try await call(f, .foldersCreate, ["name": "New", "parentFolderId": .string(UUID().uuidString)])
        XCTAssertEqual(missing.errorPayload?.code, .notFound)
        _ = try await call(f, .foldersDelete, ["folderId": .string(root.id)])
        let deleted = try await call(f, .foldersRename, ["folderId": .string(root.id), "name": "Again"])
        XCTAssertEqual(deleted.errorPayload?.message, "That folder no longer exists. List folders again.")
        let missingMembers = try await call(f, .foldersListMembers, ["folderId": .string(root.id)])
        XCTAssertEqual(missingMembers.errorPayload?.code, .notFound)
    }

    func testFolderWritesUseWriteGateAndDesiredStateMovesDoNotAddAudit() async throws {
        let f = try await fixture()
        defer { f.cleanUp() }
        let root = try folder(await call(f, .foldersCreate, ["name": "Family"]))
        let child = try folder(await call(f, .foldersCreate, ["name": "Child"]))
        let args: [String: Value] = ["folderId": .string(child.id), "parentFolderId": .string(root.id)]
        _ = try await call(f, .foldersMove, args)
        _ = try await call(f, .foldersMove, args)
        _ = try await call(f, .foldersMove, ["folderId": .string(child.id), "parentFolderId": .null])
        XCTAssertNil(f.repository.groupFolderTree.folders[child.id]?.parentFolderID)
        let audit = await f.storedAuditEntries()
        XCTAssertEqual(audit.filter { $0.action == .moveFolder }.count, 2)
        f.gates.mcpAccess = .readOnly
        for tool in [MCPTool.foldersCreate, .foldersRename, .foldersMove, .foldersDelete, .groupsMove] {
            let response = try await call(f, tool, ["name": "Blocked", "folderId": .string(root.id), "groupId": "g-test"])
            XCTAssertNotNil(response.errorPayload, tool.rawValue)
        }
        XCTAssertEqual(f.repository.groupFolderTree.folders.count, 2)
    }
}
