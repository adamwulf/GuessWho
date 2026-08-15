import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `favorites` noun group. Phase 2 ships the favorites read; the favorites
/// writes (set/reorder) land in a later phase under the same group.
public struct FavoritesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "favorites",
        abstract: "List the user's favorites in their saved order.",
        subcommands: [FavoritesList.self]
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
