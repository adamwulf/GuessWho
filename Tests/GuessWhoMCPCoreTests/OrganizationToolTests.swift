import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

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

    private func preparedFixture(writable: Bool = false) async -> Fixture {
        let fixture = await Fixture.make()
        await MainActor.run {
            if writable {
                fixture.gates.mcpAccess = .readWrite
                fixture.gates.cliAccess = .readWrite
            }
            fixture.contacts.contacts = [
                Contact(
                    localID: Self.organizationLocalID,
                    contactType: .organization,
                    organizationName: "Acme Corp",
                    note: "ORGANIZATION-PRIVATE-NOTE"),
                makeContact(localID: "ABPerson-MEMBER-Z", givenName: "Zara", department: " Engineering "),
                makeContact(localID: "ABPerson-MEMBER-A", givenName: "alice", organization: " acme corp ", department: "engineering"),
                makeContact(localID: "ABPerson-MEMBER-B", givenName: "Bob", department: "Design"),
                makeContact(localID: "ABPerson-OUTSIDER", givenName: "Outsider", organization: "Other Corp", department: "Engineering"),
            ]
        }
        return fixture
    }

    private func organizationID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: "organization", favoritesOnly: nil, groupId: nil,
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first(where: { $0.name == "Acme Corp" })?.id
    }

    private func personID(_ fixture: Fixture) async -> String? {
        let response = await fixture.dispatcher.handle(.contactsList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            kind: "person", favoritesOnly: nil, groupId: nil,
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return nil }
        return page.items.first?.id
    }

    func testOrganizationResolutionAndPersonKindMismatch() async {
        let fixture = await preparedFixture()
        guard let organizationID = await organizationID(fixture),
              let personID = await personID(fixture)
        else { return XCTFail("missing fixture ids") }

        let resolved = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = resolved else {
            return XCTFail("organization id did not resolve")
        }
        XCTAssertEqual(page.items.count, 3)

        let mismatch = await fixture.dispatcher.handle(.organizationsListDepartments(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: personID, limit: nil, cursor: nil))
        expectError(
            mismatch, code: .kindMismatch,
            message: WireErrorMessage.organizationKindMismatch)

        let unknown = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: "00000000-0000-4000-8000-000000000000",
            limit: nil, cursor: nil))
        expectError(unknown, code: .notFound, message: WireErrorMessage.notFoundContact)
    }

    func testMembersAreRepositoryDerivedAndDeterministicallyOrdered() async {
        let fixture = await preparedFixture()
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let response = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = response else { return XCTFail("expected page") }
        XCTAssertEqual(page.items.map(\.name), ["alice", "Bob", "Zara"])
        XCTAssertTrue(page.items.allSatisfy { $0.kind == "person" })
        let calls = await MainActor.run { fixture.contacts.associatedMembersReadCount }
        XCTAssertGreaterThan(calls, 0, "membership must come from the repository source")
    }

    func testDepartmentsAreStableDistinctAndPaged() async {
        let fixture = await preparedFixture()
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let first = await fixture.dispatcher.handle(.organizationsListDepartments(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 1, cursor: nil))
        guard case .departmentPage(_, _, let firstPage) = first else { return XCTFail("expected page") }
        XCTAssertEqual(firstPage.items, ["Design"])
        XCTAssertNotNil(firstPage.nextCursor)

        let second = await fixture.dispatcher.handle(.organizationsListDepartments(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 1, cursor: firstPage.nextCursor))
        guard case .departmentPage(_, _, let secondPage) = second else { return XCTFail("expected page") }
        XCTAssertEqual(secondPage.items, ["engineering"])
        XCTAssertNil(secondPage.nextCursor)
        let calls = await MainActor.run { fixture.contacts.departmentsReadCount }
        XCTAssertEqual(calls, 2)
    }

    func testDepartmentMemberLookupIsCaseInsensitiveAndAbsentIsNotFound() async {
        let fixture = await preparedFixture()
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let found = await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, department: "  EnGiNeErInG  ",
            limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = found else { return XCTFail("expected members") }
        XCTAssertEqual(page.items.map(\.name), ["alice", "Zara"])

        let absent = await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, department: "Finance",
            limit: nil, cursor: nil))
        expectError(absent, code: .notFound, message: WireErrorMessage.notFoundDepartment)
        let calls = await MainActor.run { fixture.contacts.departmentMembersReadCount }
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    func testMemberPagingUsesStandardMaximumAndStableCursorOrder() async {
        let fixture = await preparedFixture()
        await MainActor.run {
            let organization = fixture.contacts.contacts[0]
            fixture.contacts.contacts = [organization] + (0..<205).map { index in
                makeContact(
                    localID: String(format: "ABPerson-PAGED-%03d", index),
                    givenName: String(format: "Member %03d", index))
            }
        }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let first = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 500, cursor: nil))
        guard case .contactPage(_, _, let firstPage) = first else { return XCTFail("expected page") }
        XCTAssertEqual(firstPage.items.count, 200)
        XCTAssertEqual(firstPage.items.first?.name, "Member 000")
        XCTAssertEqual(firstPage.items.last?.name, "Member 199")

        let second = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 500, cursor: firstPage.nextCursor))
        guard case .contactPage(_, _, let secondPage) = second else { return XCTFail("expected page") }
        XCTAssertEqual(secondPage.items.map(\.name), [
            "Member 200", "Member 201", "Member 202", "Member 203", "Member 204",
        ])
        XCTAssertNil(secondPage.nextCursor)
    }

    func testOrganizationMemberPageUsesStandardResponseSizeCap() async {
        let fixture = await preparedFixture()
        await MainActor.run {
            let organization = fixture.contacts.contacts[0]
            fixture.contacts.contacts = [organization] + (0..<200).map { index in
                makeContact(
                    localID: "ABPerson-LARGE-\(index)",
                    givenName: String(repeating: "LargeName", count: 300) + " \(index)")
            }
        }
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let response = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: 200, cursor: nil))
        expectError(response, code: .tooLarge, message: WireErrorMessage.tooLarge)
    }

    func testRenameSuccessReportsCountUpdatesMembersAndAudits() async {
        let fixture = await preparedFixture(writable: true)
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let response = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: " engineering ", newName: "Product",
            idempotencyToken: nil))
        guard case .departmentRename(_, _, let result) = response else {
            return XCTFail("expected affected-count result, got \(String(describing: response))")
        }
        XCTAssertEqual(result.affectedCount, 2)
        let state = await MainActor.run { () -> ([String], Int) in
            let departments = fixture.contacts.contacts
                .filter { ["alice", "Zara"].contains($0.givenName) }
                .map(\.departmentName)
            return (departments, fixture.contacts.renameDepartmentCallCount)
        }
        XCTAssertEqual(state.0, ["Product", "Product"])
        XCTAssertEqual(state.1, 1, "dispatcher must make one user-level repository call")

        let entries = await fixture.audit.entries()
        let audit = entries.last(where: { $0.action == .renameDepartment })
        XCTAssertEqual(audit?.subjectName, "Acme Corp")
        XCTAssertEqual(audit?.priorValue, "engineering")
        XCTAssertEqual(audit?.newValue, "Product")
        XCTAssertNotEqual(audit?.subjectID, Self.organizationLocalID)
    }

    func testRenameValidationAndCapitalizationOnlyBehavior() async {
        let fixture = await preparedFixture(writable: true)
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let empty = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "   ",
            idempotencyToken: nil))
        expectError(empty, code: .invalidParams, message: WireErrorMessage.emptyDepartmentName)

        let same = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: " Engineering ", newName: "Engineering",
            idempotencyToken: nil))
        expectError(same, code: .invalidParams, message: WireErrorMessage.unchangedDepartmentName)

        let caseOnly = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "ENGINEERING", newName: "Engineering",
            idempotencyToken: nil))
        guard case .departmentRename(_, _, let result) = caseOnly else { return XCTFail("expected success") }
        XCTAssertEqual(result.affectedCount, 2)
    }

    func testRenameFailureAndPartialFailureAreHonestAndNonLeaking() async {
        let fixture = await preparedFixture(writable: true)
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        await MainActor.run {
            fixture.contacts.nextRenameDepartmentError = NSError(
                domain: "NSCocoaErrorDomain", code: 134092,
                userInfo: [NSLocalizedDescriptionKey: Self.organizationLocalID])
            fixture.contacts.renameDepartmentFailureAfterUpdates = 1
        }
        let response = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(response, code: .writeFailed, message: WireErrorMessage.writeFailed)
        let changedCount = await MainActor.run {
            fixture.contacts.contacts.filter { $0.departmentName == "Product" }.count
        }
        XCTAssertEqual(changedCount, 1, "fixture must prove a partial effect was not called success")
        XCTAssertFalse(response?.wireJSON.contains(Self.organizationLocalID) == true)
        XCTAssertFalse(response?.agentVisibleText.contains(Self.organizationLocalID) == true)
        let entries = await fixture.audit.entries()
        XCTAssertFalse(entries.contains { $0.action == .renameDepartment }, "failed operations are not success-audited")
    }

    func testRenameMapsRevokedPermissionAndPersonMismatchWithoutCallingRepository() async {
        let fixture = await preparedFixture(writable: true)
        guard let organizationID = await organizationID(fixture),
              let personID = await personID(fixture)
        else { return XCTFail("missing ids") }
        let mismatch = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: personID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(mismatch, code: .kindMismatch)
        let callsAfterMismatch = await MainActor.run {
            fixture.contacts.renameDepartmentCallCount
        }
        XCTAssertEqual(callsAfterMismatch, 0)

        await MainActor.run {
            fixture.contacts.nextRenameDepartmentError = NSError(
                domain: "CNErrorDomain", code: 100, userInfo: [:])
        }
        let denied = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(denied, code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
    }

    func testPermissionsAndReadWriteGateApply() async {
        let fixture = await preparedFixture()
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let readOnly = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: nil))
        expectError(readOnly, code: .readOnly, message: WireErrorMessage.readOnly)

        await MainActor.run { fixture.gates.contactsAuthorized = false }
        let readDenied = await fixture.dispatcher.handle(.organizationsListMembers(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: organizationID, limit: nil, cursor: nil))
        expectError(readDenied, code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        let renameCalls = await MainActor.run { fixture.contacts.renameDepartmentCallCount }
        XCTAssertEqual(renameCalls, 0)
    }

    func testRenameIdempotencyAndWriteBudget() async {
        let fixture = await preparedFixture(writable: true)
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let first = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: "rename-first",
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "rename-once"))
        guard case .departmentRename(_, _, let firstResult) = first else { return XCTFail("expected success") }
        let retry = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: "rename-retry",
            organizationId: organizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "rename-once"))
        guard case .departmentRename(_, let retryMessageID, let retryResult) = retry else {
            return XCTFail("expected replay")
        }
        XCTAssertEqual(retryMessageID, "rename-retry")
        XCTAssertEqual(retryResult, firstResult)
        let idempotentCalls = await MainActor.run { fixture.contacts.renameDepartmentCallCount }
        XCTAssertEqual(idempotentCalls, 1)

        let budgetFixture = await Fixture.make(writeLimitPerWindow: 1)
        await MainActor.run {
            budgetFixture.gates.mcpAccess = .readWrite
            budgetFixture.contacts.contacts = fixture.contacts.contacts
        }
        guard let budgetOrganizationID = await self.organizationID(budgetFixture) else {
            return XCTFail("missing org")
        }
        _ = await budgetFixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: budgetOrganizationID, oldName: "Product", newName: "Engineering",
            idempotencyToken: "budget-one"))
        let busy = await budgetFixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            organizationId: budgetOrganizationID, oldName: "Engineering", newName: "Product",
            idempotencyToken: "budget-two"))
        expectError(busy, code: .busy, message: WireErrorMessage.writeBusy)
        let budgetCalls = await MainActor.run {
            budgetFixture.contacts.renameDepartmentCallCount
        }
        XCTAssertEqual(budgetCalls, 1)
    }

    func testOrganizationOutputsNeverLeakLocalIdentifiers() async {
        let fixture = await preparedFixture(writable: true)
        guard let organizationID = await organizationID(fixture) else { return XCTFail("missing org") }
        let responses: [WireResponse?] = [
            await fixture.dispatcher.handle(.organizationsListMembers(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, limit: nil, cursor: nil)),
            await fixture.dispatcher.handle(.organizationsListDepartments(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, limit: nil, cursor: nil)),
            await fixture.dispatcher.handle(.organizationsListDepartmentMembers(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                organizationId: organizationID, department: "Engineering",
                limit: nil, cursor: nil)),
            await fixture.dispatcher.handle(.organizationsRenameDepartment(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
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
