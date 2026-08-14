import ArgumentParser
import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import Logging

struct ContactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Search contacts and transfer contact photos.",
        subcommands: [ContactsSearch.self, ContactsGetPhoto.self, ContactsSetPhoto.self]
    )
}

struct ContactsSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search contacts by name and visible contact fields."
    )

    @Argument(help: "Search text (at least two characters).")
    var query: String

    @Option(help: "Maximum contacts to return (default 50, max 200).")
    var limit: Int?

    @Option(help: "Paging cursor returned by a previous search.")
    var cursor: String?

    func run() async throws {
        let response = try await CLICommandClient.send(tool: .contactsSearch) {
            .contactsSearch(
                helperId: $0, messageId: $1, query: query,
                limit: limit, cursor: cursor)
        }
        try CLICommandOutput.throwIfError(response)
        guard case .contactPage(_, _, let page) = response else {
            throw ValidationError("GuessWho returned an unexpected search response.")
        }
        try CLICommandOutput.writeJSON(page)
    }
}

struct ContactsGetPhoto: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-photo",
        abstract: "Write a contact's photo to stdout or a file."
    )

    @Argument(help: "Contact id returned by contacts search.")
    var contactId: String

    @Option(name: [.short, .long], help: "Output file. Omit, or use '-', to write image bytes to stdout.")
    var output: String?

    func run() async throws {
        let response = try await CLICommandClient.send(tool: .contactsGetPhoto) {
            .contactsGetPhoto(helperId: $0, messageId: $1, contactId: contactId)
        }
        try CLICommandOutput.throwIfError(response)
        guard case .contactPhoto(_, _, let photo) = response else {
            throw ValidationError("GuessWho returned an unexpected photo response.")
        }
        guard photo.present else {
            throw ValidationError("That contact does not have a photo.")
        }
        guard let encoded = photo.dataBase64,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count == photo.byteCount
        else {
            throw ValidationError("GuessWho returned invalid photo data.")
        }

        if let output, output != "-" {
            let path = (output as NSString).expandingTildeInPath
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw ValidationError("Could not write photo to \(path): \(error.localizedDescription)")
            }
        } else {
            do {
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                throw ValidationError("Could not write photo to stdout: \(error.localizedDescription)")
            }
        }
    }
}

struct ContactsSetPhoto: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-photo",
        abstract: "Set a contact's photo from stdin or an image file."
    )

    @Argument(help: "Contact id returned by contacts search.")
    var contactId: String

    @Option(name: [.short, .long], help: "Input image file. Omit, or use '-', to read image bytes from stdin.")
    var input: String?

    @Option(help: "Token that makes a retried update apply only once.")
    var idempotencyToken: String?

    func run() async throws {
        let data = try CLIPhotoInput.read(path: input)
        guard !data.isEmpty else {
            throw ValidationError("The input image is empty.")
        }
        guard data.count <= WireEnvironment.maxContactPhotoBytes else {
            throw ValidationError("The input image is larger than 180 KiB.")
        }
        guard let mediaType = WireContactPhotoMedia.mediaType(for: data) else {
            throw ValidationError("The input must be a JPEG, PNG, GIF, HEIC, or WebP image.")
        }

        let response = try await CLICommandClient.send(tool: .contactsSetPhoto) {
            .contactsSetPhoto(
                helperId: $0, messageId: $1, contactId: contactId,
                mediaType: mediaType, dataBase64: data.base64EncodedString(),
                idempotencyToken: idempotencyToken)
        }
        try CLICommandOutput.throwIfError(response)
        guard case .acknowledged(_, _, let message) = response else {
            throw ValidationError("GuessWho returned an unexpected photo update response.")
        }
        print(message)
    }
}

private enum CLICommandClient {
    static func send(
        tool: MCPTool,
        request: (String, String) -> WireRequest
    ) async throws -> WireResponse {
        let helperId = RequestOrigin.cli.makeHelperId()
        let messageId = UUID().uuidString
        let connection = RelayConnection(
            helperId: helperId,
            container: try CLIEnvironment.container(),
            logger: Logger(label: "com.milestonemade.guesswho.cli.command")
        )

        do {
            let response = try await connection.send(
                request(helperId, messageId), timeout: tool.timeout)
            await connection.disconnect()
            return response
        } catch {
            await connection.disconnect()
            if let relayError = error as? RelayConnectionError {
                throw ValidationError(relayError.description)
            }
            throw error
        }
    }
}

private enum CLICommandOutput {
    static func throwIfError(_ response: WireResponse) throws {
        if let error = response.errorPayload {
            throw ValidationError(error.message)
        }
    }

    static func writeJSON<Payload: Encodable>(_ payload: Payload) throws {
        var data: Data
        do {
            data = try WireResponse.agentJSONEncoder.encode(payload)
        } catch {
            throw ValidationError("Could not prepare the result as JSON.")
        }
        data.append(0x0A)
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            throw ValidationError("Could not write the result to stdout: \(error.localizedDescription)")
        }
    }
}

private enum CLIPhotoInput {
    static func read(path: String?) throws -> Data {
        if let path, path != "-" {
            let expandedPath = (path as NSString).expandingTildeInPath
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath))
            } catch {
                throw ValidationError("Could not open \(expandedPath): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            return try readBounded(from: handle, source: expandedPath)
        }
        return try readBounded(from: .standardInput, source: "stdin")
    }

    private static func readBounded(from handle: FileHandle, source: String) throws -> Data {
        let maximum = WireEnvironment.maxContactPhotoBytes
        var data = Data()
        do {
            while data.count <= maximum {
                let remaining = maximum + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            throw ValidationError("Could not read image data from \(source): \(error.localizedDescription)")
        }
        return data
    }
}
