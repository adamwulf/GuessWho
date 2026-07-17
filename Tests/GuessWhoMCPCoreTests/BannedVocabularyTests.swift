import XCTest
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The product-principle grep, as a test (plans/cli-mcp.md Phase 1 exit
/// criteria): the FULL listTools output (names + descriptions + schemas),
/// every fixed error/status string, and the Preferences strings must not
/// contain seam words, adoption-seam phrasing, or implementation
/// vocabulary. "GuessWho" is allowed only inside the known product-name
/// phrases.
final class BannedVocabularyTests: XCTestCase {

    /// Substrings that must never appear (checked case-insensitively).
    private static let banned: [String] = [
        // Seam words.
        "sidecar", "unlink", "eventkit", "calendar event", "reconcile",
        "guesswho://",
        // Adoption-seam phrasing.
        "link to", "pick from existing",
        // Implementation vocabulary.
        "app group", "fifo", "named pipe", "pipe", "relay", "mach-o",
        "helperid", "stalehandle", "handle",
        // Phase 3 install/undelete surfaces (plans/cli-mcp.md): the user
        // sees "command-line access" and "Recently Deleted", never the
        // mechanism underneath.
        "symlink", "tombstone",
    ]

    /// Product-name phrases the strings legitimately use. Scanning strips
    /// these first; any remaining "guesswho" is a violation ("GuessWho as
    /// a noun for private records" stays a review judgment, but stray uses
    /// fail here).
    private static let allowedProductPhrases: [String] = [
        "GuessWho isn't open",
        "open the GuessWho app",
        "GuessWho is open",
        "GuessWho doesn't have access",
        "GuessWho's settings",
        "GuessWho didn't answer",
        "GuessWho is busy",
        "while GuessWho is open",
        "in the GuessWho app",
        "GuessWho's storage",
        "guesswho_status",
        // Phase 3 install-section copy.
        "GuessWho has moved",
        "the guesswho command",
        // Revision 2 confirmation copy.
        "bring the GuessWho app to the front",
    ]

    private func assertClean(_ text: String, context: String) {
        var stripped = text
        for phrase in Self.allowedProductPhrases {
            stripped = stripped.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
        }
        let lowered = stripped.lowercased()
        for word in Self.banned {
            XCTAssertFalse(
                lowered.contains(word),
                "banned vocabulary “\(word)” in \(context): \(text.prefix(200))")
        }
        XCTAssertFalse(
            lowered.contains("guesswho"),
            "product name outside the allowed phrases in \(context): \(text.prefix(200))")
    }

    func testToolInventoryIsPlainLanguage() throws {
        for tool in MCPTool.allCases {
            let metadata = tool.metadata
            assertClean(metadata.name, context: "tool name \(tool.rawValue)")
            assertClean(metadata.description, context: "tool description \(tool.rawValue)")
            let encoder = JSONEncoder()
            let schema = try encoder.encode(metadata)
            assertClean(
                String(decoding: schema, as: UTF8.self),
                context: "full metadata of \(tool.rawValue)")
        }
    }

    func testFixedErrorAndStatusStringsArePlainLanguage() {
        for string in WireErrorMessage.allFixedStrings {
            assertClean(string, context: "error/status string")
        }
        for string in WireAckMessage.allFixedStrings {
            assertClean(string, context: "write acknowledgement string")
        }
    }

    func testPreferencesStringsArePlainLanguage() {
        for string in PreferencesStrings.allFixedStrings {
            assertClean(string, context: "preferences string")
        }
        for string in RecentlyDeletedStrings.allFixedStrings {
            assertClean(string, context: "recently-deleted string")
        }
        for string in InstallStrings.allFixedStrings {
            assertClean(string, context: "install string")
        }
        for string in AgentActivityStrings.allFixedStrings {
            assertClean(string, context: "agent-activity string")
        }
        for string in ConfirmationStrings.allFixedStrings {
            assertClean(string, context: "confirmation string")
        }
    }

    /// Live listTools output — the AGENT-VISIBLE surface an MCP client
    /// renders (names + descriptions + schema docs), scanned end-to-end.
    /// (The relay↔app envelope around it legitimately carries routing keys
    /// like the helper id; the agent never sees those.)
    func testLiveListToolsOutputIsPlainLanguage() async throws {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(
            .listTools(helperId: Fixture.helper, messageId: "vocab"))
        guard case .toolList(_, _, let tools, let status) = response else {
            return XCTFail("expected toolList")
        }
        XCTAssertFalse(tools.isEmpty)
        let encoded = try JSONEncoder().encode(tools)
        assertClean(String(decoding: encoded, as: UTF8.self), context: "live listTools agent surface")
        if let status { assertClean(status, context: "listTools status") }
    }

    /// Error-code NAMES must never ride an agent-visible string — only the
    /// plain message does.
    func testErrorCodeNamesStayOutOfAgentText() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.contactsGet(
            helperId: Fixture.helper, messageId: "gone", contactId: "bogus-id"))
        let text = response?.agentVisibleText ?? ""
        XCTAssertFalse(text.contains("notFound"))
        XCTAssertFalse(text.contains("invalidParams"))
        XCTAssertEqual(text, WireErrorMessage.notFoundContact)
    }
}
