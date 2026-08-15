import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `events` noun group. Phase 2 ships the three event reads; the event-tag
/// writes land in a later phase under the same group.
public struct EventsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events within a date window, read one event, and list its tags.",
        subcommands: [EventsList.self, EventsGet.self, EventsListTags.self]
    )

    public init() {}
}

/// `events list` → `events_list`. JSON page of event summaries on stdout.
public struct EventsList: CLIToolCommand {
    public static let tool: MCPTool = .eventsList

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the user's events within a date window (the window may span at most one year)."
    )

    @Argument(help: "Start of the date window, ISO 8601 (for example 2026-07-01T00:00:00Z).")
    public var startDate: String

    @Argument(help: "End of the date window, ISO 8601.")
    public var endDate: String

    @Option(help: "Maximum events to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "startDate": .string(startDate),
            "endDate": .string(endDate),
        ]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `events get` → `events_get`. Full event as JSON on stdout.
public struct EventsGet: CLIToolCommand {
    public static let tool: MCPTool = .eventsGet

    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get an event's details: title, dates, location, attendees, and notes."
    )

    @Argument(help: "Event id returned by events list.")
    public var eventId: String

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        ["eventId": .string(eventId)]
    }
}

/// `events list-tags` → `events_list_tags`. JSON page of tags on stdout.
public struct EventsListTags: CLIToolCommand {
    public static let tool: MCPTool = .eventsListTags

    public static let configuration = CommandConfiguration(
        commandName: "list-tags",
        abstract: "List the tags the user has put on an event."
    )

    @Argument(help: "Event id returned by events list.")
    public var eventId: String

    @Option(help: "Maximum tags to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["eventId": .string(eventId)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}
