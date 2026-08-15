import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `links` noun group. Phase 2 ships the one connection read; the
/// connection writes (create/delete) land in a later phase under the same
/// group.
public struct LinksCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "links",
        abstract: "List the connections on a record.",
        subcommands: [LinksList.self]
    )

    public init() {}
}

/// `links list` → `links_list`. Id-first (`<id> <kind>`, §6 #5). JSON page of
/// connections on stdout.
public struct LinksList: CLIToolCommand {
    public static let tool: MCPTool = .linksList

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every connection on a record — the people, organizations, events, and places connected to it."
    )

    @Argument(help: "The record whose connections to list — a contact, event, or place id.")
    public var id: String

    @Argument(help: "\"person\", \"organization\", \"event\", or \"place\" — what kind of record the id refers to.")
    public var kind: String

    @Option(help: "Maximum connections to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "id": .string(id),
            "kind": .string(kind),
        ]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}
