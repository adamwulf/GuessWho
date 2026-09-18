import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

public struct FoldersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "folders",
        abstract: "Organize groups in folders and read their members.",
        subcommands: [FoldersList.self, FoldersMembers.self, FoldersCreate.self,
                      FoldersRename.self, FoldersMove.self, FoldersDelete.self])

    public init() {}
}

public struct FoldersList: CLIToolCommand {
    public static let tool: MCPTool = .foldersList
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List folders and their parent folders.")

    @Option(help: "Maximum items to return (default 50, max 200).")
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

public struct FoldersMembers: CLIToolCommand {
    public static let tool: MCPTool = .foldersListMembers
    public static let configuration = CommandConfiguration(
        commandName: "members",
        abstract: "List the contacts in all groups inside a folder.")

    @Argument(help: "Folder id, from folders list.")
    public var folderId: String

    @Option(help: "Maximum items to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["folderId": .string(folderId)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

public struct FoldersCreate: CLIToolCommand {
    public static let tool: MCPTool = .foldersCreate
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a folder for groups.")

    @Argument(help: "The name for the new folder.")
    public var name: String

    @Option(name: .customLong("in"), help: "Destination folder id. Omit for the top level.")
    public var parentFolderId: String?

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["name": .string(name)]
        if let parentFolderId { bag["parentFolderId"] = .string(parentFolderId) }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

public struct FoldersRename: CLIToolCommand {
    public static let tool: MCPTool = .foldersRename
    public static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a folder.")

    @Argument(help: "Folder id, from folders list.")
    public var folderId: String

    @Argument(help: "The new name for the folder.")
    public var name: String

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["folderId": .string(folderId), "name": .string(name)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

public struct FoldersMove: CLIToolCommand {
    public static let tool: MCPTool = .foldersMove
    public static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a folder and its contents into a folder, or to the top level.")

    @Argument(help: "Folder id, from folders list.")
    public var folderId: String

    @Option(name: .customLong("to"), help: "Destination folder id. Omit for the top level.")
    public var parentFolderId: String?

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["folderId": .string(folderId)]
        if let parentFolderId { bag["parentFolderId"] = .string(parentFolderId) }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

public struct FoldersDelete: CLIToolCommand {
    public static let tool: MCPTool = .foldersDelete
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a folder. Its folders and groups move up one level.")

    @Argument(help: "Folder id, from folders list.")
    public var folderId: String

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["folderId": .string(folderId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
