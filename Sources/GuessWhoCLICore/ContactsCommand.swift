import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `contacts` noun group. Its subcommands are the shipped Phase 0/1 tool
/// commands plus the Phase 2 reads; later phases add the writes under the same
/// group.
public struct ContactsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Search, list, read, create, and update contacts and their fields, notes, custom fields, groups, and photos.",
        subcommands: [
            ContactsSearch.self, ContactsList.self, ContactsGet.self,
            ContactsGetPhoto.self, ContactsSetPhoto.self,
            ContactsListNotes.self, ContactsListCustomFields.self, ContactsListGroups.self,
            ContactsAddNote.self, ContactsEditNote.self, ContactsDeleteNote.self,
            ContactsSetCustomField.self, ContactsDeleteCustomField.self,
            ContactsSetFavorite.self,
            // Phase 4 — contact-store card writes.
            ContactsCreate.self, ContactsUpdate.self, ContactsDeletePhoto.self,
        ]
    )

    public init() {}
}

/// `contacts search` → `contacts_search`. Args → bag → shared funnel → JSON
/// page of contact summaries on stdout.
public struct ContactsSearch: CLIToolCommand {
    public static let tool: MCPTool = .contactsSearch

    public static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search contacts by name and visible contact fields."
    )

    @Argument(help: "Search text (at least two characters).")
    public var query: String

    @Option(help: "Maximum contacts to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous search.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["query": .string(query)]
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `contacts get-photo` → `contacts_get_photo`. Bespoke rendering: raw photo
/// bytes to stdout or a file, with the response's integrity checks.
public struct ContactsGetPhoto: CLIToolCommand {
    public static let tool: MCPTool = .contactsGetPhoto

    public static let configuration = CommandConfiguration(
        commandName: "get-photo",
        abstract: "Write a contact's photo to stdout or a file."
    )

    @Argument(help: "Contact id returned by contacts search.")
    public var contactId: String

    @Option(name: [.short, .long], help: "Output file. Omit, or use '-', to write image bytes to stdout.")
    public var output: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        ["contactId": .string(contactId)]
    }

    public func renderResponse(_ response: WireResponse, to sink: any CLIOutput) throws {
        // A typed error uses the shared renderer (message → stderr, exit 1).
        if response.errorPayload != nil {
            let code = CLIResponseRenderer.render(response, to: sink)
            throw ExitCode(code.rawValue)
        }
        guard case .contactPhoto(_, _, let photo) = response else {
            sink.writeError("GuessWho returned an unexpected photo response.")
            throw ExitCode(CLIExitCode.appError.rawValue)
        }
        let data: Data
        do {
            data = try CLIPhotoOutput.decode(photo)
        } catch let failure as CLIPhotoOutput.Failure {
            sink.writeError(failure.message)
            throw ExitCode(CLIExitCode.appError.rawValue)
        }
        do {
            try CLIPhotoOutput.write(data, toPath: output, sink: sink)
        } catch let error as CLIUsageError {
            sink.writeError(error.message)
            throw ExitCode(CLIExitCode.usage.rawValue)
        }
    }
}

/// `contacts set-photo` → `contacts_set_photo`. Reads bounded image bytes from
/// stdin or a file, sniffs the media type, then rides the shared funnel; the
/// ack renders through the default renderer.
public struct ContactsSetPhoto: CLIToolCommand {
    public static let tool: MCPTool = .contactsSetPhoto

    public static let configuration = CommandConfiguration(
        commandName: "set-photo",
        abstract: "Set a contact's photo from stdin or an image file."
    )

    @Argument(help: "Contact id returned by contacts search.")
    public var contactId: String

    @Option(name: [.short, .long], help: "Input image file. Omit, or use '-', to read image bytes from stdin.")
    public var input: String?

    @Option(help: "Token that makes a retried update apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        let data = try CLIPhotoInput.read(path: input)
        guard !data.isEmpty else {
            throw CLIUsageError("The input image is empty.")
        }
        guard data.count <= WireEnvironment.maxContactPhotoBytes else {
            throw CLIUsageError("The input image is larger than 180 KiB.")
        }
        guard let mediaType = WireContactPhotoMedia.mediaType(for: data) else {
            throw CLIUsageError("The input must be a JPEG, PNG, GIF, HEIC, or WebP image.")
        }
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "mediaType": .string(mediaType),
            "dataBase64": .string(data.base64EncodedString()),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts list` → `contacts_list`. No positional; the filters combine.
/// JSON page of contact summaries on stdout.
public struct ContactsList: CLIToolCommand {
    public static let tool: MCPTool = .contactsList

    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List contacts ordered by name, optionally filtered by kind, favorites, or group."
    )

    @Option(help: "Only \"person\" or only \"organization\" contacts. Omit for both.")
    public var kind: String?

    @Flag(help: "Only contacts the user has marked favorite.")
    public var favoritesOnly = false

    @Option(help: "Only members of this group id, from contacts list-groups.")
    public var groupId: String?

    @Option(help: "Maximum contacts to return (default 50, max 200).")
    public var limit: Int?

    @Option(help: "Paging cursor returned by a previous page.")
    public var cursor: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [:]
        if let kind { bag["kind"] = .string(kind) }
        if favoritesOnly { bag["favoritesOnly"] = .bool(true) }
        if let groupId { bag["groupId"] = .string(groupId) }
        if let limit { bag["limit"] = .int(limit) }
        if let cursor { bag["cursor"] = .string(cursor) }
        return bag
    }
}

/// `contacts get` → `contacts_get`. Full contact card as JSON on stdout.
public struct ContactsGet: CLIToolCommand {
    public static let tool: MCPTool = .contactsGet

    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a contact's full card by id."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        ["contactId": .string(contactId)]
    }
}

/// `contacts list-notes` → `contacts_list_notes`. JSON page of notes on stdout.
public struct ContactsListNotes: CLIToolCommand {
    public static let tool: MCPTool = .contactsListNotes

    public static let configuration = CommandConfiguration(
        commandName: "list-notes",
        abstract: "List the dated notes the user has written about a contact."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Option(help: "Maximum notes to return (default 50, max 200).")
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

/// `contacts list-custom-fields` → `contacts_list_custom_fields`. JSON page of
/// custom fields on stdout.
public struct ContactsListCustomFields: CLIToolCommand {
    public static let tool: MCPTool = .contactsListCustomFields

    public static let configuration = CommandConfiguration(
        commandName: "list-custom-fields",
        abstract: "List the custom fields the user has added to a contact."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Option(help: "Maximum fields to return (default 50, max 200).")
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

/// `contacts list-groups` → `contacts_list_groups`. No positional. JSON page of
/// groups on stdout.
public struct ContactsListGroups: CLIToolCommand {
    public static let tool: MCPTool = .contactsListGroups

    public static let configuration = CommandConfiguration(
        commandName: "list-groups",
        abstract: "List the user's contact groups, including whether each is a favorite."
    )

    @Option(help: "Maximum groups to return (default 50, max 200).")
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

/// `contacts add-note` → `contacts_add_note`. The body arrives via `--body`
/// (inline / `-` stdin / `--body-file`); the new note echoes back as JSON.
public struct ContactsAddNote: CLIToolCommand {
    public static let tool: MCPTool = .contactsAddNote

    public static let configuration = CommandConfiguration(
        commandName: "add-note",
        abstract: "Add a dated note about a contact."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Option(help: "The note's text. Use '-' to read the text from stdin.")
    public var body: String?

    @Option(help: "Read the note's text from this file instead of --body.")
    public var bodyFile: String?

    @Option(help: "Token that makes a retried add apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "body": .string(try CLITextInput.read(inline: body, file: bodyFile)),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts edit-note` → `contacts_edit_note`. Replaces one note's text; the
/// body arrives via `--body` (inline / `-` stdin / `--body-file`).
public struct ContactsEditNote: CLIToolCommand {
    public static let tool: MCPTool = .contactsEditNote

    public static let configuration = CommandConfiguration(
        commandName: "edit-note",
        abstract: "Replace the text of one of the user's notes about a contact."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "Note id returned by contacts list-notes.")
    public var noteId: String

    @Option(help: "The note's new text. Use '-' to read the text from stdin.")
    public var body: String?

    @Option(help: "Read the note's new text from this file instead of --body.")
    public var bodyFile: String?

    @Option(help: "Token that makes a retried edit apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "noteId": .string(noteId),
            "body": .string(try CLITextInput.read(inline: body, file: bodyFile)),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-note` → `contacts_delete_note`. Answers with a fixed ack.
public struct ContactsDeleteNote: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeleteNote

    public static let configuration = CommandConfiguration(
        commandName: "delete-note",
        abstract: "Delete one of the user's notes about a contact."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "Note id returned by contacts list-notes.")
    public var noteId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "noteId": .string(noteId),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// The custom-field types a caller may set. Raw values match the wire enum
/// (`contacts_set_custom_field`'s `type`); ArgumentParser validates the flag
/// against these and lists them in `--help`.
public enum CLICustomFieldType: String, ExpressibleByArgument, CaseIterable {
    case text
    case multilineNote
    case date
    case checkbox
}

/// `contacts set-custom-field` → `contacts_set_custom_field`. Upserts a named
/// field; the field echoes back as JSON.
public struct ContactsSetCustomField: CLIToolCommand {
    public static let tool: MCPTool = .contactsSetCustomField

    public static let configuration = CommandConfiguration(
        commandName: "set-custom-field",
        abstract: "Add or update a named custom field on a contact. An existing field with that name has its value replaced."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "The field's name, e.g. \"Coffee order\".")
    public var name: String

    @Argument(help: "The field's value: text; an ISO 8601 date for a date field; \"true\" or \"false\" for a checkbox.")
    public var value: String

    @Option(help: "The field's type: text, multilineNote, date, or checkbox. Defaults to text.")
    public var type: CLICustomFieldType?

    @Option(help: "Token that makes a retried update apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "name": .string(name),
            "value": .string(value),
        ]
        if let type { bag["type"] = .string(type.rawValue) }
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-custom-field` → `contacts_delete_custom_field`. Answers with
/// a fixed ack.
public struct ContactsDeleteCustomField: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeleteCustomField

    public static let configuration = CommandConfiguration(
        commandName: "delete-custom-field",
        abstract: "Delete a custom field from a contact."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Argument(help: "Field id returned by contacts list-custom-fields.")
    public var fieldId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "fieldId": .string(fieldId),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts set-favorite` → `contacts_set_favorite`. Desired-state, not a
/// toggle: `--favorite` / `--no-favorite` is required. Answers with a fixed ack.
public struct ContactsSetFavorite: CLIToolCommand {
    public static let tool: MCPTool = .contactsSetFavorite

    public static let configuration = CommandConfiguration(
        commandName: "set-favorite",
        abstract: "Mark a contact as a favorite, or remove it from favorites."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Flag(inversion: .prefixedNo, help: "Whether the contact is a favorite. Required: pass --favorite or --no-favorite.")
    public var favorite: Bool?

    @Option(help: "Token that makes a retried change apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        guard let favorite else {
            throw CLIUsageError("Pass --favorite or --no-favorite.")
        }
        var bag: [String: Value] = [
            "contactId": .string(contactId),
            "favorite": .bool(favorite),
        ]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
