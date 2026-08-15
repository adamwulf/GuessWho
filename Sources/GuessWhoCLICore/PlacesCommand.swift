import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `places` noun group. Phase 2 ships the three place reads; the place
/// delete write lands in a later phase under the same group.
public struct PlacesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "places",
        abstract: "List and search saved places, read one by id, and delete one.",
        subcommands: [PlacesList.self, PlacesSearch.self, PlacesGet.self, PlacesDelete.self]
    )

    public init() {}
}

/// `places list` → `places_list`. No positional. JSON page of places on stdout.
public struct PlacesList: CLIToolCommand {
    public static let tool: MCPTool = .placesList

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved places, optionally within one guide."
    )

    @Option(help: "Only this guide's places; pass a guide id from guides list.")
    public var guideId: String?

    @Option(help: "Maximum places to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [:]
        if let guideId { bag["guideId"] = .string(guideId) }
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `places search` → `places_search`. JSON page of places on stdout.
public struct PlacesSearch: CLIToolCommand {
    public static let tool: MCPTool = .placesSearch

    public static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search saved places by visible place name, address, or guide name."
    )

    @Argument(help: "Text to find in a place's name or address, or in its guide's name.")
    public var query: String

    @Option(help: "Maximum places to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["query": .string(query)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `places get` → `places_get`. One place as JSON on stdout.
public struct PlacesGet: CLIToolCommand {
    public static let tool: MCPTool = .placesGet

    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get one saved place by id."
    )

    @Argument(help: "Place id returned by places list or places search.")
    public var placeId: String

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        ["placeId": .string(placeId)]
    }
}

/// `places delete` → `places_delete`. Answers with a fixed ack.
public struct PlacesDelete: CLIToolCommand {
    public static let tool: MCPTool = .placesDelete

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one place from a guide."
    )

    @Argument(help: "Place id returned by places list or places search.")
    public var placeId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["placeId": .string(placeId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
