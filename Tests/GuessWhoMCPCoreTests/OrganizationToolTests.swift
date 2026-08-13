import XCTest
import GuessWhoSync
import GuessWhoSyncTesting
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Organization tool parity tests over the PRODUCTION dispatch stack
/// (`MCPProductionFixture`): a real `ContactsRepository` supplies the
/// company/department matching, sorting, and rename — none of it re-derived in
/// test code — and the substituted OS boundary (`RecordingContactStore`)
/// injects the one save fault a partial-rename test needs at a chosen ordinal.
///
/// The seeded members below carry sentinels the leak tests hunt for (raw
/// `ABPerson-` local ids, a `PRIVATE-` Apple note) exactly where they must NOT
/// escape, so the same INV assertions apply as with the fake fixture.
@MainActor
final class OrganizationToolTests: XCTestCase {
    private static let organizationLocalID = "ABPerson-ORG-LOCAL-DO-NOT-LEAK"

    private func expectError(
        _ response: WireResponse?, code: WireErrorCode, message: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let payload = response?.errorPayload else {
            return XCTFail("expected \(code), got \(String(describing: response))", file: file, line: line)
        }
        XCTAssertEqual(payload.code, code, file: file, line: line)
        if let message { XCTAssertEqual(payload.message, message, file: file, line: line) }
    }

    private func makeContact(
        localID: String, givenName: String, familyName: String = "",
        organization: String = "Acme Corp", department: String = "Engineering"
    ) -> Contact {
        Contact(
            localID: localID, givenName: givenName, familyName: familyName,
            departmentName: department, organizationName: organization,
            note: "PRIVATE-\(localID)")
    }

    /// A production fixture seeded with an "Acme Corp" organization and its
    /// people, on top of the harness's default book. The organization is a
    /// distinct company from the harness's "Analytical Engines," so its member
    /// and department queries are isolated to the people seeded here.
    private func preparedFixture(
        writable: Bool = false, writeLimitPerWindow: Int = 30
    ) async throws -> MCPProductionFixture {
        let fixture = try await MCPProductionFixture.make(
            writeLimitPerWindow: writeLimitPerWindow)
        if writable {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        do {
            try await fixture.seedContacts([
                Contact(
                    localID: Self.organizationLocalID,
                    contactType: .organization,
                    organizationName: "Acme Corp",
                    note: "ORGANIZATION-PRIVATE-NOTE"),
                makeContact(localID: "ABPerson-MEMBER-Z", givenName: "Zara", department: " Engineering "),
                makeContact(localID: "ABPerson-MEMBER-A", givenName: "alice", organization: " acme corp ", department: "engineering"),
                makeContact(localID: "ABPerson-MEMBER-B", givenName: "Bob", department: "Design"),
                makeContact(localID: "ABPerson-OUTSIDER", givenName: "Outsider", organization: "Other Corp", department: "Engineering"),
            ])
        } catch {
            fixture.cleanUp()
            throw error
        }
        return fixture
    }

    private func organizationID(_ fixture: MCPProductionFixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            kind: "organization", favoritesOnly: nil, groupId: nil,
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.name == "Acme Corp" })?.id
    }

    private func personID(_ fixture: MCPProductionFixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            kind: "person", favoritesOnly: nil, groupId: nil,
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first?.id
    }

    func testOrganizationResolutionAndPersonKindMismatch() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture),
              let personID = await personID(fixture)
        else { return XCTFail("missing fixture ids") }

        let resolved = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = resolved else {
            return XCTFail("organization id did not resolve")
        }
        XCTAssertEqual(page.items.count, 3)

        let mismatch = await fixture.dispatcher.handle(.organizationsListDepartments(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: personID, limit: nil, cursor: nil))
        expectError(
            mismatch, code: .kindMismatch,
            message: WireErrorMessage.organizationKindMismatch)

        let unknown = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: "00000000-0000-4000-8000-000000000000",
            limit: nil, cursor: nil))
        expectError(unknown, code: .notFound, message: WireErrorMessage.notFoundContact)
    }

    func testMembersAreRepositoryDerivedAndDeterministicallyOrdered() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let response = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return XCTFail("expected page") }
        // Membership + ordering come from the real repository's company match
        // (case-insensitive, trimmed) and display-name sort — there is no other
        // source in this harness, so the correct set proves it is derived there.
        XCTAssertEqual(page.items.map(\.name), ["alice", "Bob", "Zara"])
        XCTAssertTrue(page.items.allSatisfy { $0.kind == "person" })
    }

    func testDepartmentsAreStableDistinctAndPaged() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let first = await fixture.dispatcher.handle(.organizationsListDepartments(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 1, cursor: nil))
        guard case .departmentPage(_, _, let firstPage) = first else { return XCTFail("expected page") }
        XCTAssertEqual(firstPage.items, ["Design"])
        XCTAssertNotNil(firstPage.nextCursor)

        let second = await fixture.dispatcher.handle(.organizationsListDepartments(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 1, cursor: firstPage.nextCursor))
        guard case .departmentPage(_, _, let secondPage) = second else { return XCTFail("expected page") }
        // Distinct case-insensitively (the first-seen "engineering" display form
        // wins over Zara's " Engineering ") and sorted A–Z.
        XCTAssertEqual(secondPage.items, ["engineering"])
        XCTAssertNil(secondPage.nextCursor)
    }

    func testDepartmentMemberLookupIsCaseInsensitiveAndAbsentIsNotFound() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let found = await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, department: "  EnGiNeErInG  ",
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = found else { return XCTFail("expected members") }
        XCTAssertEqual(page.items.map(\.name), ["alice", "Zara"])

        let absent = await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, department: "Finance",
            limit: nil, cursor: nil))
        expectError(absent, code: .notFound, message: WireErrorMessage.notFoundDepartment)

        let blank = await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, department: "   ",
            limit: nil, cursor: nil))
        expectError(blank, code: .invalidParams, message: WireErrorMessage.emptyDepartmentName)
    }

    func testMemberPagingUsesStandardMaximumAndStableCursorOrder() async throws {
        let fixture = try await MCPProductionFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.seedContacts(
            [Contact(
                localID: Self.organizationLocalID,
                contactType: .organization,
                organizationName: "Acme Corp",
                note: "ORGANIZATION-PRIVATE-NOTE")]
            + (0..<205).map { index in
                makeContact(
                    localID: String(format: "ABPerson-PAGED-%03d", index),
                    givenName: String(format: "Member %03d", index))
            })
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let first = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 500, cursor: nil))
        guard case .contactPage(_, _, let firstPage) = first else { return XCTFail("expected page") }
        XCTAssertEqual(firstPage.items.count, 200)
        XCTAssertEqual(firstPage.items.first?.name, "Member 000")
        XCTAssertEqual(firstPage.items.last?.name, "Member 199")

        let second = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 500, cursor: firstPage.nextCursor))
        guard case .contactPage(_, _, let secondPage) = second else { return XCTFail("expected page") }
        XCTAssertEqual(secondPage.items.map(\.name), [
            "Member 200", "Member 201", "Member 202", "Member 203", "Member 204",
        ])
        XCTAssertNil(secondPage.nextCursor)
    }

    func testOrganizationMemberPageUsesStandardResponseSizeCap() async throws {
        let fixture = try await MCPProductionFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.seedContacts(
            [Contact(
                localID: Self.organizationLocalID,
                contactType: .organization,
                organizationName: "Acme Corp",
                note: "ORGANIZATION-PRIVATE-NOTE")]
            + (0..<200).map { index in
                makeContact(
                    localID: "ABPerson-LARGE-\(index)",
                    givenName: String(repeating: "LargeName", count: 300) + " \(index)")
            })
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let response = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 200, cursor: nil))
        expectError(response, code: .tooLarge, message: WireErrorMessage.tooLarge)
    }

    func testRenameSuccessReportsCountUpdatesMembersAndAudits() async throws {
        let fixture = try await preparedFixture(writable: true)
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let baseline = await fixture.store.saveCount
        let response = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: " engineering ", newName: "Product",
            idempotencyToken: nil))
        guard case .departmentRename(_, _, let result) = response else {
            return XCTFail("expected affected-count result, got \(String(describing: response))")
        }
        XCTAssertEqual(result.affectedCount, 2)

        // The store records prove both matching members really changed — the
        // real repository re-fetched, edited, and saved each one.
        let alice = try await fixture.store.fetch(localID: "ABPerson-MEMBER-A")
        let zara = try await fixture.store.fetch(localID: "ABPerson-MEMBER-Z")
        XCTAssertEqual(alice?.departmentName, "Product")
        XCTAssertEqual(zara?.departmentName, "Product")
        // Exactly one store save per matching member — no extra writes.
        let saves = await fixture.store.saveCount
        XCTAssertEqual(saves, baseline + 2, "one save per matching member, nothing more")

        let entries = await fixture.audit.entries()
        let audit = entries.last(where: { $0.action == .renameDepartment })
        XCTAssertEqual(audit?.subjectName, "Acme Corp")
        XCTAssertEqual(audit?.priorValue, "engineering")
        XCTAssertEqual(audit?.newValue, "Product")
        XCTAssertNotEqual(audit?.subjectID, Self.organizationLocalID)
    }

    func testRenameValidationAndCapitalizationOnlyBehavior() async throws {
        let fixture = try await preparedFixture(writable: true)
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let empty = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "   ",
            idempotencyToken: nil))
        expectError(empty, code: .invalidParams, message: WireErrorMessage.emptyDepartmentName)

        let same = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: " Engineering ", newName: "Engineering",
            idempotencyToken: nil))
        expectError(same, code: .invalidParams, message: WireErrorMessage.unchangedDepartmentName)

        let caseOnly = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "ENGINEERING", newName: "Engineering",
            idempotencyToken: nil))
        guard case .departmentRename(_, _, let result) = caseOnly else { return XCTFail("expected success") }
        XCTAssertEqual(result.affectedCount, 2)
    }

    /// The NEW production-backed partial-save coverage. Two members share the
    /// "Engineering" department; the store rejects the SECOND member's save
    /// (the Cocoa 134092 store-rejection family) at a chosen ordinal, so the
    /// real repository commits the first member and then throws. The dispatcher
    /// must report a typed, non-leaking failure that never claims zero changed,
    /// the store + a fresh reload must prove exactly one durable effect, and a
    /// retry (a failed write is never idempotency-cached) must heal the rest.
    func testRenamePartialSaveFailureIsHonestNonLeakingAndRetryable() async throws {
        let fixture = try await preparedFixture(writable: true)
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }

        // "alice" sorts before "Zara," so the second member save is Zara's;
        // reject exactly that one (ordinal counting is seed-excluded, so anchor
        // on the live save count to stay robust to any earlier writes).
        let baseline = await fixture.store.saveCount
        let rejection = NSError(
            domain: "NSCocoaErrorDomain", code: 134092,
            userInfo: [NSLocalizedDescriptionKey: Self.organizationLocalID])
        await fixture.store.failSave(atOrdinal: baseline + 2, with: rejection)

        let response = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "rename-partial"))
        expectError(response, code: .writeFailed, message: WireErrorMessage.writeFailed)

        // First save durable, later save unchanged — the store is the truth.
        // Zara was seeded with the untrimmed " Engineering "; the rejected save
        // left her record byte-for-byte unchanged, whitespace included.
        let alice = try await fixture.store.fetch(localID: "ABPerson-MEMBER-A")
        let zara = try await fixture.store.fetch(localID: "ABPerson-MEMBER-Z")
        XCTAssertEqual(alice?.departmentName, "Product", "the first member's save committed")
        XCTAssertEqual(zara?.departmentName, " Engineering ", "the rejected save left the second member unchanged")
        let saves = await fixture.store.saveCount
        XCTAssertEqual(saves, baseline + 2, "the boundary counted the rejected attempt too")
        let committed = await fixture.store.committedSaveLocalIDs
        XCTAssertTrue(committed.contains("ABPerson-MEMBER-A"))
        XCTAssertFalse(committed.contains("ABPerson-MEMBER-Z"))

        // Repository cache/reload honesty: a full refresh reflects exactly the
        // durable partial effect — one renamed, one not — hiding nothing.
        await fixture.reload()
        XCTAssertEqual(fixture.contact(localID: "ABPerson-MEMBER-A")?.departmentName, "Product")
        XCTAssertEqual(fixture.contact(localID: "ABPerson-MEMBER-Z")?.departmentName, " Engineering ")

        // The typed failure never leaks the private local id or note.
        XCTAssertFalse(response?.wireJSON.contains(Self.organizationLocalID) == true)
        XCTAssertFalse(response?.agentVisibleText.contains(Self.organizationLocalID) == true)
        XCTAssertFalse(response?.wireJSON.contains("ABPerson-") == true)

        // A failed write is never success-audited.
        let entries = await fixture.audit.entries()
        XCTAssertFalse(entries.contains { $0.action == .renameDepartment })

        // Idempotency: the failed write was NOT cached, so retrying the same
        // token re-executes (it does not replay a phantom success) and heals
        // the one member that never changed.
        let retry = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "rename-partial"))
        guard case .departmentRename(_, _, let healed) = retry else {
            return XCTFail("a retry after a failed write must re-run, got \(String(describing: retry))")
        }
        XCTAssertEqual(healed.affectedCount, 1, "only the still-unchanged member remains to rename")
        await fixture.reload()
        XCTAssertEqual(fixture.contact(localID: "ABPerson-MEMBER-Z")?.departmentName, "Product")
        let entriesAfterRetry = await fixture.audit.entries()
        XCTAssertTrue(
            entriesAfterRetry.contains { $0.action == .renameDepartment },
            "the healing write IS success-audited")
    }

    func testRenameMapsRevokedPermissionAndPersonMismatchWithoutCallingRepository() async throws {
        let fixture = try await preparedFixture(writable: true)
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture),
              let personID = await personID(fixture)
        else { return XCTFail("missing ids") }
        let baseline = await fixture.store.saveCount
        let mismatch = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: personID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(mismatch, code: .kindMismatch)
        let savesAfterMismatch = await fixture.store.saveCount
        XCTAssertEqual(savesAfterMismatch, baseline, "a kind mismatch never reaches a repository write")

        // A Contacts authorization-denied error at the first member save maps
        // to a permission-denied wire error.
        await fixture.store.failSave(
            atOrdinal: savesAfterMismatch + 1,
            with: NSError(domain: "CNErrorDomain", code: 100, userInfo: [:]))
        let denied = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(denied, code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
    }

    func testPermissionsAndReadWriteGateApply() async throws {
        let fixture = try await preparedFixture()
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let readOnly = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(readOnly, code: .readOnly, message: WireErrorMessage.readOnly)

        fixture.gates.contactsAuthorized = false
        let readDenied = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: nil, cursor: nil))
        expectError(readDenied, code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        let saves = await fixture.store.saveCount
        XCTAssertEqual(saves, 0)
    }

    func testRenameIdempotencyAndWriteBudget() async throws {
        let fixture = try await preparedFixture(writable: true)
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let first = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: "rename-first",
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "rename-once"))
        guard case .departmentRename(_, _, let firstResult) = first else { return XCTFail("expected success") }
        let savesAfterFirst = await fixture.store.saveCount
        let retry = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: "rename-retry",
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "rename-once"))
        guard case .departmentRename(_, let retryMessageID, let retryResult) = retry else {
            return XCTFail("expected replay")
        }
        XCTAssertEqual(retryMessageID, "rename-retry")
        XCTAssertEqual(retryResult, firstResult)
        let savesAfterRetry = await fixture.store.saveCount
        XCTAssertEqual(savesAfterRetry, savesAfterFirst, "a replay does not re-run the repository write")

        let budgetFixture = try await preparedFixture(
            writable: true, writeLimitPerWindow: 1)
        defer { budgetFixture.cleanUp() }
        guard let budgetOrganizationID = await self.organizationID(budgetFixture) else {
            return XCTFail("missing org")
        }
        let budgetBaseline = await budgetFixture.store.saveCount
        _ = await budgetFixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: budgetOrganizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "budget-one"))
        let busy = await budgetFixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            organizationId: budgetOrganizationID, oldName: "Product", newName: "Design",
            idempotencyToken: "budget-two"))
        expectError(busy, code: .busy, message: WireErrorMessage.writeBusy)
        let budgetSaves = await budgetFixture.store.saveCount
        XCTAssertEqual(budgetSaves, budgetBaseline + 2, "only the first rename reached the store")
    }

    func testOrganizationOutputsNeverLeakLocalIdentifiers() async throws {
        let fixture = try await preparedFixture(writable: true)
        defer { fixture.cleanUp() }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let responses: [WireResponse?] = [
            await fixture.dispatcher.handle(.organizationsListMembers(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, limit: nil, cursor: nil)),
            await fixture.dispatcher.handle(.organizationsListDepartments(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, limit: nil, cursor: nil)),
            await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, department: "Engineering",
                limit: nil, cursor: nil)),
            await fixture.dispatcher.handle(.organizationsRenameDepartment(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, oldName: "Engineering", newName: "Product",
                idempotencyToken: nil)),
        ]
        for response in responses.compactMap({ $0 }) {
            XCTAssertFalse(response.wireJSON.contains("ABPerson-"))
            XCTAssertFalse(response.agentVisibleText.contains("ABPerson-"))
            XCTAssertFalse(response.agentVisibleText.contains("PRIVATE-"))
        }
    }
}
