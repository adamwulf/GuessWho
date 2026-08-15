import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `favorites` noun group. Phase 2 ships the favorites read; the favorites
/// writes (set/reorder) land in a later phase under the same group.
public struct FavoritesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "favorites",
        abstract: "List the user's favorites in their saved order, set whether an item is a favorite, and reorder them.",
        subcommands: [FavoritesList.self, FavoritesSet.self, FavoritesReorder.self]
    )

    public init() {}
}

/// `favorites list` → `favorites_list`. No positional. JSON page of favorites
/// on stdout.
public struct FavoritesList: CLIToolCommand {
    public static let tool: MCPTool = .favoritesList

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the user's favorites in their saved order, each with its kind, id, and display name."
    )

    @Option(help: "Maximum favorites to return (default 50, max 200).")
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

/// `favorites set` → `favorites_set`. Desired-state, not a toggle:
/// `--favorite` / `--no-favorite` is required. Answers with a fixed ack.
public struct FavoritesSet: CLIToolCommand {
    public static let tool: MCPTool = .favoritesSet

    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set whether one contact, event, group, guide, or place is a favorite."
    )

    @Argument(help: "\"contact\", \"event\", \"group\", \"guide\", or \"place\".")
    public var kind: String

    @Argument(help: "The item's id, from the matching list command or favorites list.")
    public var id: String

    @Flag(inversion: .prefixedNo, help: "Whether the item is a favorite. Required: pass --favorite or --no-favorite.")
    public var favorite: Bool?

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        guard let favorite else {
            throw CLIUsageError("Pass --favorite or --no-favorite.")
        }
        var bag: [String: Value] = [
            "kind": .string(kind),
            "id": .string(id),
            "favorite": .bool(favorite),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `favorites reorder` → `favorites_reorder`. The complete favorites array of
/// `{kind, id}` pairs arrives via `--json` (inline / `-` stdin / `--json-file`)
/// and goes straight into the bag under the `favorites` key, so the wire builder
/// is the single validator. Answers with a fixed ack.
public struct FavoritesReorder: CLIToolCommand {
    public static let tool: MCPTool = .favoritesReorder

    public static let configuration = CommandConfiguration(
        commandName: "reorder",
        abstract: "Replace the favorites order without changing the set. Pass every current favorite exactly once as a {kind, id} pair, in the desired order."
    )

    @Option(help: "A JSON array of {\"kind\", \"id\"} pairs in the desired order. Use '-' to read the JSON from stdin.")
    public var json: String?

    @Option(help: "Read the JSON array from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried reorder apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [:]
        if let value = try CLIJSONInput.read(inline: json, file: jsonFile) {
            try CLIJSONInput.assign(value, toKey: "favorites", in: &bag)
        }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
