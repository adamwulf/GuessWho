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
        abstract: "List the connections on a record, connect two records, and remove a connection.",
        subcommands: [LinksList.self, LinksCreate.self, LinksDelete.self]
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

/// `links create` → `links_create`. Connects two records, with an optional note
/// about the connection; the new connection echoes back as JSON. (This `--note`
/// is the connection's own note, not the Apple contact note.)
public struct LinksCreate: CLIToolCommand {
    public static let tool: MCPTool = .linksCreate

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Connect two records, with an optional note about the connection."
    )

    @Argument(help: "The first record's id — a contact, event, or place id.")
    public var fromId: String

    @Argument(help: "\"person\", \"organization\", \"event\", or \"place\" — what kind of record fromId is.")
    public var fromKind: String

    @Argument(help: "The second record's id — a contact, event, or place id.")
    public var toId: String

    @Argument(help: "\"person\", \"organization\", \"event\", or \"place\" — what kind of record toId is.")
    public var toKind: String

    @Option(help: "A short note about the connection, e.g. \"Met at this cafe\".")
    public var note: String?

    @Option(help: "Token that makes a retried create apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "fromId": .string(fromId),
            "fromKind": .string(fromKind),
            "toId": .string(toId),
            "toKind": .string(toKind),
        ]
        if let note { bag["note"] = .string(note) }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `links delete` → `links_delete`. Answers with a fixed ack.
public struct LinksDelete: CLIToolCommand {
    public static let tool: MCPTool = .linksDelete

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove a connection between two records."
    )

    @Argument(help: "Connection id returned by links list or links create.")
    public var linkId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["linkId": .string(linkId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
