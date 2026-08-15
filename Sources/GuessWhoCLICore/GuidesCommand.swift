import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `guides` noun group. Phase 2 ships the three guide reads; the guide
/// writes (create/delete/reorder) land in a later phase under the same group.
public struct GuidesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "guides",
        abstract: "List saved place guides, read one, and find the guides that contain a place.",
        subcommands: [GuidesList.self, GuidesGet.self, GuidesListForPlace.self]
    )

    public init() {}
}

/// `guides list` → `guides_list`. No positional. JSON page of guides on stdout.
public struct GuidesList: CLIToolCommand {
    public static let tool: MCPTool = .guidesList

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the user's saved place guides."
    )

    @Option(help: "Maximum guides to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [:]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `guides get` → `guides_get`. One guide as JSON on stdout.
public struct GuidesGet: CLIToolCommand {
    public static let tool: MCPTool = .guidesGet

    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get one saved place guide by id."
    )

    @Argument(help: "Guide id returned by guides list.")
    public var guideId: String

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        ["guideId": .string(guideId)]
    }
}

/// `guides list-for-place` → `guides_list_for_place`. JSON page of guides on
/// stdout.
public struct GuidesListForPlace: CLIToolCommand {
    public static let tool: MCPTool = .guidesListForPlace

    public static let configuration = CommandConfiguration(
        commandName: "list-for-place",
        abstract: "List every saved guide containing the same visible address as one place."
    )

    @Argument(help: "Place id returned by places list or places search.")
    public var placeId: String

    @Option(help: "Maximum guides to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["placeId": .string(placeId)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}
