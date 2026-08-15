import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// `contacts delete` → `contacts_delete`. The one confirmation-gated command:
/// the app presents a Delete/Cancel dialog naming the specific contact, and the
/// user's deferred answer rides the normal response pipe. The send therefore
/// blocks up to the tool's own 300 s timeout (`Self.tool.timeout`, inherited
/// from the shared funnel), which is the human's window to answer.
///
/// Two bespoke pieces on top of the shared funnel:
///
/// - a pre-send note on STDERR, so an interactive user knows the command is
///   waiting on the in-app confirmation rather than hung; and
/// - a custom `renderResponse` that splits the two acks by their
///   `WireAckMessage` constant. DELETED is a normal success (stdout, exit 0).
///   DECLINED is a normal wire result too, but the CLI makes it
///   terminal-and-distinct — message → stderr, exit 10, stdout empty — so a
///   script can branch on "not deleted" (§4, §6 #1). Any typed error
///   (`requiresAppAction`, `writeFailed`, `permissionDenied`, `notFound`, …)
///   takes the shared error path: message → stderr, exit 1.
public struct ContactsDelete: CLIToolCommand {
    public static let tool: MCPTool = .contactsDelete

    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a contact. The user must confirm the deletion in the GuessWho app first."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    /// Written to stderr as the send begins: the delete waits on the user's
    /// answer in the app, so an interactive caller sees why it's blocking.
    public var preSendNote: String? {
        "GuessWho is asking for your approval — check the app."
    }

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }

    public func renderResponse(_ response: WireResponse, to sink: any CLIOutput) throws {
        // Distinguish the two acks by their WireAckMessage CONSTANT, never by
        // the English text.
        if case .acknowledged(_, _, let message) = response {
            switch message {
            case WireAckMessage.contactDeleted:
                // The user approved: normal success on stdout, exit 0.
                sink.writeLine(message)
                return
            case WireAckMessage.contactDeleteDeclined:
                // The user cancelled: a terminal, non-retryable outcome. Print
                // the message to stderr and exit 10 so stdout stays empty and a
                // script can branch on "not deleted".
                sink.writeError(message)
                throw ExitCode(CLIExitCode.declinedDelete.rawValue)
            default:
                break
            }
        }
        // Any other response — a typed error or an unexpected ack — is exactly
        // the shared renderer's job: message → stderr, exit 1.
        let code = CLIResponseRenderer.render(response, to: sink)
        if code != .success { throw ExitCode(code.rawValue) }
    }
}
