import ArgumentParser
import Foundation
import XCTest
@testable import GuessWhoCLICore

/// The product-principle grep over the CLI's help surface (§3.3): every
/// command's abstract, discussion, and per-argument help must avoid seam words
/// and implementation vocabulary. Same banned list as
/// Tests/GuessWhoMCPCoreTests/BannedVocabularyTests.swift:14-27, applied to the
/// help text ArgumentParser renders.
final class VocabularyTests: XCTestCase {

    /// Substrings that must never appear (checked case-insensitively) — copied
    /// verbatim from BannedVocabularyTests.banned.
    private static let banned: [String] = [
        // Seam words.
        "sidecar", "unlink", "eventkit", "calendar event", "reconcile",
        "guesswho://",
        // Adoption-seam phrasing.
        "link to", "pick from existing",
        // Implementation vocabulary.
        "app group", "fifo", "named pipe", "pipe", "relay", "mach-o",
        "helperid", "stalehandle", "handle",
        // Install/undelete surfaces.
        "symlink", "tombstone",
    ]

    private func assertClean(_ text: String, context: String) {
        let lowered = text.lowercased()
        for word in Self.banned {
            XCTAssertFalse(
                lowered.contains(word),
                "banned vocabulary “\(word)” in \(context): \(text.prefix(200))")
        }
    }

    func testEveryCommandsHelpIsPlainLanguage() {
        assertClean(
            GuessWhoCLIRoot.helpMessage(includeHidden: true, columns: 1000),
            context: "root help")
        for type in CLICommandRegistry.allSubcommandTypes {
            let name = type.configuration.commandName ?? String(describing: type)
            assertClean(
                type.helpMessage(includeHidden: true, columns: 1000),
                context: "help for \(name)")
        }
    }

    /// The scan reaches every command reachable from the root (a sanity check
    /// that the walk isn't silently empty).
    func testScanCoversEveryCommand() {
        // run + probe (2), eight noun groups (contacts, organizations, groups,
        // events, guides, places, links, favorites), and the tool commands
        // beneath them: 3 shipped + 20 Phase 2 reads + 6 Phase 3 contacts writes
        // + 2 Phase 3 favorites writes + 3 Phase 3 event-tag writes + 3 Phase 3
        // guide writes (create, delete, reorder-places) + 1 Phase 3 place delete
        // = 38. 2 + 8 + 38 = 48.
        XCTAssertEqual(CLICommandRegistry.allSubcommandTypes.count, 48)
    }
}
