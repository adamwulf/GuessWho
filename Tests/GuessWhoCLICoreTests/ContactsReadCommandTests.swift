import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the Phase 2 contacts reads, and render for the
/// contact card, notes page, custom-fields page, and groups page shapes.
final class ContactsReadCommandTests: CLICommandTestCase {

    // MARK: contacts list — parse

    func testListParsesNoArguments() throws {
        let command = try ContactsList.parse([])
        XCTAssertNil(command.kind)
        XCTAssertFalse(command.favoritesOnly)
        XCTAssertNil(command.groupId)
        XCTAssertNil(command.limit)
        XCTAssertNil(command.cursor)
    }

    func testListParsesAllFilters() throws {
        let command = try ContactsList.parse([
            "--kind", "organization", "--favorites-only",
            "--group-id", "g1", "--limit", "25", "--cursor", "abc",
        ])
        XCTAssertEqual(command.kind, "organization")
        XCTAssertTrue(command.favoritesOnly)
        XCTAssertEqual(command.groupId, "g1")
        XCTAssertEqual(command.limit, 25)
        XCTAssertEqual(command.cursor, "abc")
    }

    // MARK: contacts list — request build

    func testListBuildsExpectedRequestWithAllFilters() throws {
        let command = try ContactsList.parse([
            "--kind", "person", "--favorites-only", "--group-id", "g1",
            "--limit", "25", "--cursor", "abc",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsList(
            helperId: "cli-test", messageId: "m1", kind: "person",
            favoritesOnly: true, groupId: "g1", limit: 25, cursor: "abc")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testListBuildsExpectedRequestWhenEmpty() throws {
        let command = try ContactsList.parse([])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsList(
            helperId: "cli-test", messageId: "m1", kind: nil,
            favoritesOnly: nil, groupId: nil, limit: nil, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts get — parse + request build

    func testGetParsesContactId() throws {
        XCTAssertEqual(try ContactsGet.parse(["c1"]).contactId, "c1")
    }

    func testGetMissingContactIdIsAParseError() {
        XCTAssertThrowsError(try ContactsGet.parse([]))
    }

    func testGetBuildsExpectedRequest() throws {
        let command = try ContactsGet.parse(["c1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsGet.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsGet(helperId: "cli-test", messageId: "m1", contactId: "c1")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts list-notes — parse + request build

    func testListNotesParsesIdAndPaging() throws {
        let command = try ContactsListNotes.parse(["c1", "--limit", "3", "--cursor", "n"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.limit, 3)
        XCTAssertEqual(command.cursor, "n")
    }

    func testListNotesBuildsExpectedRequest() throws {
        let command = try ContactsListNotes.parse(["c1", "--limit", "3"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsListNotes.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsListNotes(
            helperId: "cli-test", messageId: "m1", contactId: "c1", limit: 3, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts list-custom-fields — parse + request build

    func testListCustomFieldsParsesIdAndPaging() throws {
        let command = try ContactsListCustomFields.parse(["c1", "--cursor", "f"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertNil(command.limit)
        XCTAssertEqual(command.cursor, "f")
    }

    func testListCustomFieldsBuildsExpectedRequest() throws {
        let command = try ContactsListCustomFields.parse(["c1", "--cursor", "f"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsListCustomFields.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsListCustomFields(
            helperId: "cli-test", messageId: "m1", contactId: "c1", limit: nil, cursor: "f")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts list-groups — parse + request build

    func testListGroupsParsesPagingOnly() throws {
        let command = try ContactsListGroups.parse(["--limit", "9"])
        XCTAssertEqual(command.limit, 9)
        XCTAssertNil(command.cursor)
    }

    func testListGroupsBuildsExpectedRequest() throws {
        let command = try ContactsListGroups.parse(["--limit", "9"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsListGroups.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsListGroups(
            helperId: "cli-test", messageId: "m1", limit: 9, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — contact card

    func testGetRendersContactCardAsJSON() async throws {
        let contact = Self.sampleContact
        let response = WireResponse.contact(helperId: "h", messageId: "m", contact: contact)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsGet.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(contact) + "\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    // MARK: Render — notes page

    func testListNotesRendersNotePageAsJSON() async throws {
        let page = WirePage(items: [
            WireNote(id: "n1", body: "First met at the fair.",
                     createdAt: "2026-01-02T00:00:00Z", modifiedAt: "2026-01-02T00:00:00Z"),
        ], nextCursor: "next")
        let response = WireResponse.notePage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsListNotes.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Render — custom-fields page

    func testListCustomFieldsRendersCustomFieldPageAsJSON() async throws {
        let page = WirePage(items: [
            WireCustomField(id: "f1", name: "Coffee order", type: "text",
                            value: "Flat white", modifiedAt: "2026-01-02T00:00:00Z"),
        ], nextCursor: nil)
        let response = WireResponse.customFieldPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsListCustomFields.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Render — groups page

    func testListGroupsRendersGroupPageAsJSON() async throws {
        let page = WirePage(items: [
            WireGroup(id: "g1", name: "Book club", isFavorite: true),
        ], nextCursor: nil)
        let response = WireResponse.groupPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsListGroups.parse([])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Fixtures

    static let sampleContact = WireContact(
        id: "c1", kind: "person", name: "Ada Lovelace",
        namePrefix: nil, givenName: "Ada", middleName: nil,
        familyName: "Lovelace", previousFamilyName: nil, nameSuffix: nil,
        nickname: nil,
        phoneticGivenName: nil, phoneticMiddleName: nil, phoneticFamilyName: nil,
        organization: "Analytical Engines", phoneticOrganization: nil,
        department: nil, jobTitle: "Programmer",
        phoneNumbers: [WireLabeledValue(label: "mobile", value: "+1 555 0100")],
        emailAddresses: [], postalAddresses: [], urlAddresses: [],
        birthday: "1815-12-10", dates: [],
        socialProfiles: [], instantMessages: [],
        relatedNames: [], isFavorite: false)
}
