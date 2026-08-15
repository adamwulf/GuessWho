import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// `contacts create` → `contacts_create`. Scalars arrive as per-field flags
/// (`ContactScalarOptions`); the multi-value list fields (phone numbers, email
/// addresses, postal addresses, and so on) arrive as one JSON object through
/// `--json` / `--json-file`. Both feed one argument bag and the shared
/// `WireRequest.create`, so a key given by both a flag and `--json` is a usage
/// error, never a silent merge. The new card echoes back as JSON.
public struct ContactsCreate: CLIToolCommand {
    public static let tool: MCPTool = .contactsCreate

    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new contact. Set single-value fields with the per-field flags; supply the list fields (phone numbers, email addresses, postal addresses, and so on) as a JSON object with --json. An empty string clears a field."
    )

    @OptionGroup public var scalars: ContactScalarOptions

    @Option(help: "The list fields as a JSON object, e.g. {\"emailAddresses\":[{\"label\":\"work\",\"value\":\"a@b.com\"}]}. Use '-' to read the JSON from stdin.")
    public var json: String?

    @Option(help: "Read the list-fields JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried create apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [:]
        scalars.assignScalars(into: &bag)
        if let payload = try CLIJSONInput.read(inline: json, file: jsonFile) {
            guard case .object(let fields) = payload else {
                throw CLIUsageError("The --json value must be a JSON object of list fields.")
            }
            for (key, value) in fields {
                try CLIJSONInput.assign(value, toKey: key, in: &bag)
            }
        }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts update` → `contacts_update`. SCALARS-ONLY by wire construction:
/// the update field set has no list members, so a whole-list bulk edit can't
/// ride an update — list fields change one entry at a time through the
/// value/structured commands. Only the flags that are passed apply (the wire's
/// PATCH rule); an empty string clears that field. The updated card echoes back.
public struct ContactsUpdate: CLIToolCommand {
    public static let tool: MCPTool = .contactsUpdate

    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a contact's single-value fields. Only the flags you pass change; an empty string clears a field. List fields (phone numbers, addresses, and so on) change one entry at a time through contacts add-value / edit-value / delete-value and the structured-entry commands."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var scalars: ContactScalarOptions

    @Option(help: "Token that makes a retried update apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        scalars.assignScalars(into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-photo` → `contacts_delete_photo`. Answers with a fixed ack.
public struct ContactsDeletePhoto: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeletePhoto

    public static let configuration = CommandConfiguration(
        commandName: "delete-photo",
        abstract: "Remove a contact's photo."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
