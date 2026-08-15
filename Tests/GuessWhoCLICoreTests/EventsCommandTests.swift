import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the event reads, and render for the event page,
/// full event, and tag page shapes.
final class EventsCommandTests: CLICommandTestCase {

    // MARK: events list — parse + request build

    func testListParsesWindowAndPaging() throws {
        let command = try EventsList.parse([
            "2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", "--limit", "20", "--cursor", "e",
        ])
        XCTAssertEqual(command.startDate, "2026-07-01T00:00:00Z")
        XCTAssertEqual(command.endDate, "2026-08-01T00:00:00Z")
        XCTAssertEqual(command.limit, 20)
        XCTAssertEqual(command.cursor, "e")
    }

    func testListMissingEndDateIsAParseError() {
        XCTAssertThrowsError(try EventsList.parse(["2026-07-01T00:00:00Z"]))
    }

    func testListBuildsExpectedRequest() throws {
        let command = try EventsList.parse(["2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", "--limit", "20"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.eventsList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.eventsList(
            helperId: "cli-test", messageId: "m1",
            startDate: "2026-07-01T00:00:00Z", endDate: "2026-08-01T00:00:00Z",
            limit: 20, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: events get — parse + request build

    func testGetParsesEventId() throws {
        XCTAssertEqual(try EventsGet.parse(["e1"]).eventId, "e1")
    }

    func testGetBuildsExpectedRequest() throws {
        let command = try EventsGet.parse(["e1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.eventsGet.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.eventsGet(helperId: "cli-test", messageId: "m1", eventId: "e1")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: events list-tags — parse + request build

    func testListTagsParsesIdAndPaging() throws {
        let command = try EventsListTags.parse(["e1", "--limit", "4"])
        XCTAssertEqual(command.eventId, "e1")
        XCTAssertEqual(command.limit, 4)
    }

    func testListTagsBuildsExpectedRequest() throws {
        let command = try EventsListTags.parse(["e1", "--limit", "4"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.eventsListTags.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.eventsListTags(
            helperId: "cli-test", messageId: "m1", eventId: "e1", limit: 4, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — event page

    func testListRendersEventPageAsJSON() async throws {
        let page = WirePage(items: [
            WireEventSummary(id: "e1", title: "Fundraiser",
                             startDate: "2026-07-04T18:00:00Z", endDate: "2026-07-04T21:00:00Z",
                             isAllDay: false, location: "City Hall", calendarName: "Work"),
        ], nextCursor: "next")
        let response = WireResponse.eventPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try EventsList.parse(["2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Render — full event

    func testGetRendersEventAsJSON() async throws {
        let event = WireEvent(
            id: "e1", title: "Fundraiser",
            startDate: "2026-07-04T18:00:00Z", endDate: "2026-07-04T21:00:00Z",
            isAllDay: false, location: "City Hall", calendarName: "Work",
            notes: "Bring the banner.",
            attendees: [WireEventAttendee(name: "Ada Lovelace", email: "ada@example.com")])
        let response = WireResponse.event(helperId: "h", messageId: "m", event: event)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try EventsGet.parse(["e1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(event) + "\n")
    }

    // MARK: Render — tag page

    func testListTagsRendersTagPageAsJSON() async throws {
        let page = WirePage(items: [
            WireTag(id: "t1", text: "fundraiser", createdAt: "2026-07-01T00:00:00Z"),
        ], nextCursor: nil)
        let response = WireResponse.tagPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try EventsListTags.parse(["e1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }
}
