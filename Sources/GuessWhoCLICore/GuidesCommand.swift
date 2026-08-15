import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `guides` noun group. Phase 2 ships the three guide reads; the guide
/// writes (create/delete/reorder) land in a later phase under the same group.
public struct GuidesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "guides",
        abstract: "List saved place guides, read one, find the guides that contain a place, and create, delete, or reorder the places in a guide.",
        subcommands: [
            GuidesList.self, GuidesGet.self, GuidesListForPlace.self,
            GuidesCreate.self, GuidesDelete.self, GuidesReorderPlaces.self,
        ]
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

/// `guides create` → `guides_create`. The optional initial `places` array
/// arrives via `--json` (inline / `-` stdin / `--json-file`) and goes straight
/// into the bag under the `places` key, so the wire builder is the single
/// validator. The new guide echoes back as JSON.
public struct GuidesCreate: CLIToolCommand {
    public static let tool: MCPTool = .guidesCreate

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new place guide, optionally with an initial list of places."
    )

    @Argument(help: "The guide's name, e.g. \"Coffee Crawl\".")
    public var name: String

    @Option(help: "Optional JSON array of the guide's initial places, each {\"address\", optional \"latitude\", \"longitude\"}. Use '-' to read the JSON from stdin.")
    public var json: String?

    @Option(help: "Read the places JSON array from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried create apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["name": .string(name)]
        if let value = try CLIJSONInput.read(inline: json, file: jsonFile) {
            try CLIJSONInput.assign(value, toKey: "places", in: &bag)
        }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `guides delete` → `guides_delete`. Answers with a fixed ack.
public struct GuidesDelete: CLIToolCommand {
    public static let tool: MCPTool = .guidesDelete

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a place guide and the places in it."
    )

    @Argument(help: "Guide id returned by guides list.")
    public var guideId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["guideId": .string(guideId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `guides reorder-places` → `guides_reorder_places`. Every place id in the
/// guide, in the new order, as variadic positionals → the `placeIds` key.
/// Answers with a fixed ack.
public struct GuidesReorderPlaces: CLIToolCommand {
    public static let tool: MCPTool = .guidesReorderPlaces

    public static let configuration = CommandConfiguration(
        commandName: "reorder-places",
        abstract: "Reorder the places in a guide. Pass every place id in the guide, in the new order."
    )

    @Argument(help: "Guide id returned by guides list.")
    public var guideId: String

    @Argument(help: "Every place id in the guide (from places list), in the desired order.")
    public var placeIds: [String]

    @Option(help: "Token that makes a retried reorder apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "guideId": .string(guideId),
            "placeIds": .array(placeIds.map { .string($0) }),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
