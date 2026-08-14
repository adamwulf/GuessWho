import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The `contacts` noun group. Its subcommands are the shipped Phase 0/1 tool
/// commands; Phase 2+ adds the rest under the same group.
public struct ContactsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Search contacts and transfer contact photos.",
        subcommands: [ContactsSearch.self, ContactsGetPhoto.self, ContactsSetPhoto.self]
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
