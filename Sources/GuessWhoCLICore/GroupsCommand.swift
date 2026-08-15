import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `groups` noun group. Phase 2 ships the one group read; the group writes
/// (create/rename/delete/members/favorite) land in a later phase under the same
/// group.
public struct GroupsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Read the groups a contact belongs to.",
        subcommands: [GroupsListForContact.self]
    )

    public init() {}
}

/// `groups list-for-contact` → `groups_list_for_contact`. JSON page of groups
/// on stdout.
public struct GroupsListForContact: CLIToolCommand {
    public static let tool: MCPTool = .groupsListForContact

    public static let configuration = CommandConfiguration(
        commandName: "list-for-contact",
        abstract: "List the groups that contain a contact, including whether each is a favorite."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Option(help: "Maximum groups to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}
