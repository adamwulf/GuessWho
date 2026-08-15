import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `organizations` noun group. Phase 2 ships the three organization reads;
/// the department rename write lands in a later phase under the same group.
public struct OrganizationsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "organizations",
        abstract: "List an organization's members and departments.",
        subcommands: [
            OrganizationsListMembers.self,
            OrganizationsListDepartments.self,
            OrganizationsListDepartmentMembers.self,
        ]
    )

    public init() {}
}

/// `organizations list-members` → `organizations_list_members`. JSON page of
/// contact summaries on stdout.
public struct OrganizationsListMembers: CLIToolCommand {
    public static let tool: MCPTool = .organizationsListMembers

    public static let configuration = CommandConfiguration(
        commandName: "list-members",
        abstract: "List the people whose organization field matches an organization contact."
    )

    @Argument(help: "Organization contact id, from contacts search or contacts list.")
    public var organizationId: String

    @Option(help: "Maximum people to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["organizationId": .string(organizationId)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `organizations list-departments` → `organizations_list_departments`. JSON
/// page of department names on stdout.
public struct OrganizationsListDepartments: CLIToolCommand {
    public static let tool: MCPTool = .organizationsListDepartments

    public static let configuration = CommandConfiguration(
        commandName: "list-departments",
        abstract: "List the distinct departments represented by an organization's members."
    )

    @Argument(help: "Organization contact id, from contacts search or contacts list.")
    public var organizationId: String

    @Option(help: "Maximum departments to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["organizationId": .string(organizationId)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `organizations list-department-members` →
/// `organizations_list_department_members`. JSON page of contact summaries on
/// stdout.
public struct OrganizationsListDepartmentMembers: CLIToolCommand {
    public static let tool: MCPTool = .organizationsListDepartmentMembers

    public static let configuration = CommandConfiguration(
        commandName: "list-department-members",
        abstract: "List the people in one of an organization's departments."
    )

    @Argument(help: "Organization contact id, from contacts search or contacts list.")
    public var organizationId: String

    @Argument(help: "Department name, from organizations list-departments.")
    public var department: String

    @Option(help: "Maximum people to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "organizationId": .string(organizationId),
            "department": .string(department),
        ]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}
