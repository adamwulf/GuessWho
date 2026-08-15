import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The list-field a single-entry value edit targets. Raw values match the wire
/// enum (`WireContactListField`); ArgumentParser validates the positional
/// against these and lists them in `--help`, and the wire re-checks the value.
public enum CLIContactListField: String, ExpressibleByArgument, CaseIterable {
    case phone
    case email
    case url
    case relatedName = "related_name"
    case date
}

/// `contacts add-value` → `contacts_add_value`. Adds one entry to a list field
/// (a phone number, email address, web address, related name, or date). The
/// updated card echoes back as JSON.
public struct ContactsAddValue: CLIToolCommand {
    public static let tool: MCPTool = .contactsAddValue

    public static let configuration = CommandConfiguration(
        commandName: "add-value",
        abstract: "Add one entry to a contact's list field (phone, email, url, related_name, or date)."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "Which list field to add to.")
    public var field: CLIContactListField

    @Argument(help: "The value to add, e.g. a phone number or email address.")
    public var value: String

    @Option(help: "Optional label for the entry, e.g. home or work.")
    public var label: String?

    @Option(help: "Token that makes a retried add apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "field": .string(field.rawValue),
            "value": .string(value),
        ]
        if let label { bag["label"] = .string(label) }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-value` → `contacts_delete_value`. Removes the one entry that
/// matches the value exactly (0 matches → notFound, more than one → ambiguous;
/// nothing changes in either case). The updated card echoes back.
public struct ContactsDeleteValue: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeleteValue

    public static let configuration = CommandConfiguration(
        commandName: "delete-value",
        abstract: "Delete one entry from a contact's list field, matched by its exact value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "Which list field to delete from.")
    public var field: CLIContactListField

    @Argument(help: "The exact value to delete.")
    public var value: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "field": .string(field.rawValue),
            "value": .string(value),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts edit-value` → `contacts_edit_value`. Replaces the value (and,
/// optionally, the label) of the one entry that matches the current value
/// exactly. The updated card echoes back.
public struct ContactsEditValue: CLIToolCommand {
    public static let tool: MCPTool = .contactsEditValue

    public static let configuration = CommandConfiguration(
        commandName: "edit-value",
        abstract: "Replace one entry in a contact's list field, matched by its exact current value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "Which list field to edit.")
    public var field: CLIContactListField

    @Argument(help: "The exact current value of the entry to edit.")
    public var currentValue: String

    @Argument(help: "The new value to store in its place.")
    public var newValue: String

    @Option(help: "Optional new label for the entry, e.g. home or work.")
    public var newLabel: String?

    @Option(help: "Token that makes a retried edit apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "field": .string(field.rawValue),
            "currentValue": .string(currentValue),
            "newValue": .string(newValue),
        ]
        if let newLabel { bag["newLabel"] = .string(newLabel) }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
