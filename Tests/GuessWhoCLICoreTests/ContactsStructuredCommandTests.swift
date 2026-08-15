import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the nine structured-entry commands. Add/delete
/// assemble the object from per-field flags (the five wire-required postal
/// strings default to ""); edit proves the `--json` pair and the
/// `--current-*`/`--new-*` per-field path build the SAME request. One render
/// case confirms the contact-card echo.
final class ContactsStructuredCommandTests: CLICommandTestCase {

    // MARK: helpers

    private func built(_ tool: MCPTool, _ bag: [String: Value]) throws -> WireRequest {
        try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(name: tool.rawValue, arguments: bag))
    }

    // MARK: postal add — per-field, five required default to ""

    func testAddPostalPartialDefaultsRequiredComponentsToEmpty() throws {
        let command = try ContactsAddPostalAddress.parse(["c1", "--city", "Austin"])
        let request = try built(.contactsAddPostalAddress, command.argumentBag())
        let expected = WireRequest.contactsAddPostalAddress(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            address: WirePostalAddress(
                label: nil, street: "", subLocality: nil, city: "Austin",
                subAdministrativeArea: nil, state: "", postalCode: "", country: "",
                isoCountryCode: nil),
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testAddPostalFullBuildsExpectedRequest() throws {
        let command = try ContactsAddPostalAddress.parse([
            "c1", "--label", "home", "--street", "1 Main St", "--city", "Austin",
            "--state", "TX", "--postal-code", "78701", "--country", "USA",
            "--idempotency-token", "tok",
        ])
        let request = try built(.contactsAddPostalAddress, command.argumentBag())
        let expected = WireRequest.contactsAddPostalAddress(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            address: WirePostalAddress(
                label: "home", street: "1 Main St", subLocality: nil, city: "Austin",
                subAdministrativeArea: nil, state: "TX", postalCode: "78701",
                country: "USA", isoCountryCode: nil),
            idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testDeletePostalBuildsExpectedRequest() throws {
        let command = try ContactsDeletePostalAddress.parse([
            "c1", "--street", "1 Main St", "--city", "Austin",
            "--state", "TX", "--postal-code", "78701", "--country", "USA",
        ])
        let request = try built(.contactsDeletePostalAddress, command.argumentBag())
        let expected = WireRequest.contactsDeletePostalAddress(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            address: WirePostalAddress(
                label: nil, street: "1 Main St", subLocality: nil, city: "Austin",
                subAdministrativeArea: nil, state: "TX", postalCode: "78701",
                country: "USA", isoCountryCode: nil),
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testAddPostalFlagAndJSONConflictIsUsageError() throws {
        let command = try ContactsAddPostalAddress.parse([
            "c1", "--city", "Austin",
            "--json", "{\"street\":\"\",\"city\":\"Austin\",\"state\":\"\",\"postalCode\":\"\",\"country\":\"\"}",
        ])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    // MARK: postal edit — --json pair and per-field build the same request

    func testEditPostalPerFieldAndJSONBuildSameRequest() throws {
        let expected = WireRequest.contactsEditPostalAddress(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            currentAddress: WirePostalAddress(
                label: "home", street: "1 Main St", subLocality: nil, city: "Austin",
                subAdministrativeArea: nil, state: "TX", postalCode: "78701",
                country: "USA", isoCountryCode: nil),
            newAddress: WirePostalAddress(
                label: "home", street: "2 Oak Ave", subLocality: nil, city: "Austin",
                subAdministrativeArea: nil, state: "TX", postalCode: "78702",
                country: "USA", isoCountryCode: nil),
            idempotencyToken: nil)

        let perField = try ContactsEditPostalAddress.parse([
            "c1",
            "--current-label", "home", "--current-street", "1 Main St", "--current-city", "Austin",
            "--current-state", "TX", "--current-postal-code", "78701", "--current-country", "USA",
            "--new-label", "home", "--new-street", "2 Oak Ave", "--new-city", "Austin",
            "--new-state", "TX", "--new-postal-code", "78702", "--new-country", "USA",
        ])
        let json = """
        {"currentAddress":{"label":"home","street":"1 Main St","city":"Austin","state":"TX","postalCode":"78701","country":"USA"},\
        "newAddress":{"label":"home","street":"2 Oak Ave","city":"Austin","state":"TX","postalCode":"78702","country":"USA"}}
        """
        let viaJSON = try ContactsEditPostalAddress.parse(["c1", "--json", json])

        let fromFlags = try built(.contactsEditPostalAddress, perField.argumentBag())
        let fromJSON = try built(.contactsEditPostalAddress, viaJSON.argumentBag())
        XCTAssertEqual(try canonicalEncoding(fromFlags), try canonicalEncoding(expected))
        XCTAssertEqual(try canonicalEncoding(fromJSON), try canonicalEncoding(expected))
    }

    // MARK: social add/delete/edit

    func testAddSocialBuildsExpectedRequest() throws {
        let command = try ContactsAddSocialProfile.parse([
            "c1", "--service", "LinkedIn", "--username", "grace",
        ])
        let request = try built(.contactsAddSocialProfile, command.argumentBag())
        let expected = WireRequest.contactsAddSocialProfile(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            profile: WireSocialProfile(label: nil, service: "LinkedIn", username: "grace", url: nil),
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testDeleteSocialBuildsExpectedRequest() throws {
        let command = try ContactsDeleteSocialProfile.parse([
            "c1", "--service", "LinkedIn", "--username", "grace",
        ])
        let request = try built(.contactsDeleteSocialProfile, command.argumentBag())
        let expected = WireRequest.contactsDeleteSocialProfile(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            profile: WireSocialProfile(label: nil, service: "LinkedIn", username: "grace", url: nil),
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testEditSocialPerFieldAndJSONBuildSameRequest() throws {
        let expected = WireRequest.contactsEditSocialProfile(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            currentProfile: WireSocialProfile(label: nil, service: "LinkedIn", username: "grace", url: nil),
            newProfile: WireSocialProfile(label: nil, service: "LinkedIn", username: "grace-hopper", url: nil),
            idempotencyToken: nil)

        let perField = try ContactsEditSocialProfile.parse([
            "c1", "--current-service", "LinkedIn", "--current-username", "grace",
            "--new-service", "LinkedIn", "--new-username", "grace-hopper",
        ])
        let json = """
        {"currentProfile":{"service":"LinkedIn","username":"grace"},\
        "newProfile":{"service":"LinkedIn","username":"grace-hopper"}}
        """
        let viaJSON = try ContactsEditSocialProfile.parse(["c1", "--json", json])

        XCTAssertEqual(
            try canonicalEncoding(try built(.contactsEditSocialProfile, perField.argumentBag())),
            try canonicalEncoding(expected))
        XCTAssertEqual(
            try canonicalEncoding(try built(.contactsEditSocialProfile, viaJSON.argumentBag())),
            try canonicalEncoding(expected))
    }

    // MARK: instant-message add/delete/edit

    func testAddInstantMessageBuildsExpectedRequest() throws {
        let command = try ContactsAddInstantMessage.parse([
            "c1", "--service", "Signal", "--username", "grace",
        ])
        let request = try built(.contactsAddInstantMessage, command.argumentBag())
        let expected = WireRequest.contactsAddInstantMessage(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            instantMessage: WireInstantMessage(label: nil, service: "Signal", username: "grace"),
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testDeleteInstantMessageBuildsExpectedRequest() throws {
        let command = try ContactsDeleteInstantMessage.parse([
            "c1", "--service", "Signal", "--username", "grace",
        ])
        let request = try built(.contactsDeleteInstantMessage, command.argumentBag())
        let expected = WireRequest.contactsDeleteInstantMessage(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            instantMessage: WireInstantMessage(label: nil, service: "Signal", username: "grace"),
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
    }

    func testEditInstantMessagePerFieldAndJSONBuildSameRequest() throws {
        let expected = WireRequest.contactsEditInstantMessage(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            currentInstantMessage: WireInstantMessage(label: nil, service: "Signal", username: "grace"),
            newInstantMessage: WireInstantMessage(label: nil, service: "Signal", username: "grace-h"),
            idempotencyToken: nil)

        let perField = try ContactsEditInstantMessage.parse([
            "c1", "--current-service", "Signal", "--current-username", "grace",
            "--new-service", "Signal", "--new-username", "grace-h",
        ])
        let json = """
        {"currentInstantMessage":{"service":"Signal","username":"grace"},\
        "newInstantMessage":{"service":"Signal","username":"grace-h"}}
        """
        let viaJSON = try ContactsEditInstantMessage.parse(["c1", "--json", json])

        XCTAssertEqual(
            try canonicalEncoding(try built(.contactsEditInstantMessage, perField.argumentBag())),
            try canonicalEncoding(expected))
        XCTAssertEqual(
            try canonicalEncoding(try built(.contactsEditInstantMessage, viaJSON.argumentBag())),
            try canonicalEncoding(expected))
    }

    // MARK: Render — contact-card echo

    func testAddPostalRendersContactCardEcho() async throws {
        let contact = ContactsReadCommandTests.sampleContact
        let response = WireResponse.contact(helperId: "h", messageId: "m", contact: contact)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsAddPostalAddress.parse(["c1", "--city", "Austin"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(contact) + "\n")
    }
}
