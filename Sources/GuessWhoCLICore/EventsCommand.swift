import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `events` noun group. Phase 2 ships the three event reads; the event-tag
/// writes land in a later phase under the same group.
public struct EventsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events within a date window, read one event, and list, add, edit, or delete its tags.",
        subcommands: [
            EventsList.self, EventsGet.self, EventsListTags.self,
            EventsAddTag.self, EventsEditTag.self, EventsDeleteTag.self,
        ]
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

/// `events add-tag` → `events_add_tag`. The new tag echoes back as JSON.
public struct EventsAddTag: CLIToolCommand {
    public static let tool: MCPTool = .eventsAddTag

    public static let configuration = CommandConfiguration(
        commandName: "add-tag",
        abstract: "Put a tag on an event."
    )

    @Argument(help: "Event id returned by events list.")
    public var eventId: String

    @Argument(help: "The tag's text, e.g. \"fundraiser\".")
    public var text: String

    @Option(help: "Token that makes a retried add apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "eventId": .string(eventId),
            "text": .string(text),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `events edit-tag` → `events_edit_tag`. The updated tag echoes back as JSON.
public struct EventsEditTag: CLIToolCommand {
    public static let tool: MCPTool = .eventsEditTag

    public static let configuration = CommandConfiguration(
        commandName: "edit-tag",
        abstract: "Replace the text of a tag on an event."
    )

    @Argument(help: "Event id returned by events list.")
    public var eventId: String

    @Argument(help: "Tag id returned by events list-tags.")
    public var tagId: String

    @Argument(help: "The tag's new text.")
    public var text: String

    @Option(help: "Token that makes a retried edit apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "eventId": .string(eventId),
            "tagId": .string(tagId),
            "text": .string(text),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `events delete-tag` → `events_delete_tag`. Answers with a fixed ack.
public struct EventsDeleteTag: CLIToolCommand {
    public static let tool: MCPTool = .eventsDeleteTag

    public static let configuration = CommandConfiguration(
        commandName: "delete-tag",
        abstract: "Delete a tag from an event."
    )

    @Argument(help: "Event id returned by events list.")
    public var eventId: String

    @Argument(help: "Tag id returned by events list-tags.")
    public var tagId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "eventId": .string(eventId),
            "tagId": .string(tagId),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
