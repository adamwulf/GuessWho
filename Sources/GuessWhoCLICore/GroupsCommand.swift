import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `groups` noun group. Phase 2 ships the one group read; Phase 4 adds the
/// group writes (create/rename/delete/members/favorite) under the same group.
public struct GroupsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Read the groups a contact belongs to, and create, rename, delete, and change the membership and favorite flag of groups.",
        subcommands: [
            GroupsListForContact.self,
            GroupsCreate.self, GroupsRename.self, GroupsDelete.self,
            GroupsAddMembers.self, GroupsRemoveMembers.self, GroupsSetFavorite.self,
        ]
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

/// `groups create` → `groups_create`. Creates a new, empty group. The new group
/// echoes back as JSON.
public struct GroupsCreate: CLIToolCommand {
    public static let tool: MCPTool = .groupsCreate

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new contact group."
    )

    @Argument(help: "The name for the new group.")
    public var name: String

    @Option(help: "Token that makes a retried create apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["name": .string(name)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `groups rename` → `groups_rename`. Renames a group. The updated group echoes
/// back as JSON.
public struct GroupsRename: CLIToolCommand {
    public static let tool: MCPTool = .groupsRename

    public static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a contact group."
    )

    @Argument(help: "Group id, from contacts list-groups.")
    public var groupId: String

    @Argument(help: "The new name for the group.")
    public var name: String

    @Option(help: "Token that makes a retried rename apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "groupId": .string(groupId),
            "name": .string(name),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `groups delete` → `groups_delete`. Deletes a group (the contacts in it are
/// unaffected). Answers with a fixed ack.
public struct GroupsDelete: CLIToolCommand {
    public static let tool: MCPTool = .groupsDelete

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a contact group. The contacts in it are not deleted."
    )

    @Argument(help: "Group id, from contacts list-groups.")
    public var groupId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["groupId": .string(groupId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `groups add-members` → `groups_add_members`. Adds up to 200 contacts to a
/// group in one call. Answers with a JSON membership result (which contacts were
/// applied, and any that could not be).
public struct GroupsAddMembers: CLIToolCommand {
    public static let tool: MCPTool = .groupsAddMembers

    public static let configuration = CommandConfiguration(
        commandName: "add-members",
        abstract: "Add one or more contacts (up to 200) to a group."
    )

    @Argument(help: "Group id, from contacts list-groups.")
    public var groupId: String

    @Argument(help: "One or more contact ids to add to the group.")
    public var contactIds: [String]

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "groupId": .string(groupId),
            "contactIds": .array(contactIds.map { .string($0) }),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `groups remove-members` → `groups_remove_members`. Removes up to 200 contacts
/// from a group in one call. Answers with a JSON membership result.
public struct GroupsRemoveMembers: CLIToolCommand {
    public static let tool: MCPTool = .groupsRemoveMembers

    public static let configuration = CommandConfiguration(
        commandName: "remove-members",
        abstract: "Remove one or more contacts (up to 200) from a group."
    )

    @Argument(help: "Group id, from contacts list-groups.")
    public var groupId: String

    @Argument(help: "One or more contact ids to remove from the group.")
    public var contactIds: [String]

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "groupId": .string(groupId),
            "contactIds": .array(contactIds.map { .string($0) }),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `groups set-favorite` → `groups_set_favorite`. Desired-state, not a toggle:
/// `--favorite` / `--no-favorite` is required. The updated group echoes back.
public struct GroupsSetFavorite: CLIToolCommand {
    public static let tool: MCPTool = .groupsSetFavorite

    public static let configuration = CommandConfiguration(
        commandName: "set-favorite",
        abstract: "Mark a group as a favorite, or remove it from favorites."
    )

    @Argument(help: "Group id, from contacts list-groups.")
    public var groupId: String

    @Flag(inversion: .prefixedNo, help: "Whether the group is a favorite. Required: pass --favorite or --no-favorite.")
    public var favorite: Bool?

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        guard let favorite else {
            throw CLIUsageError("Pass --favorite or --no-favorite.")
        }
        var bag: [String: Value] = [
            "groupId": .string(groupId),
            "favorite": .bool(favorite),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
