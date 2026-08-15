import Foundation
import GuessWhoMCPWire
import XCTest
@testable import GuessWhoCLICore

/// The parity guard (§3.4): every `MCPTool` case has a CLI command whose path
/// matches the §2 derivation rule, and every registered command names a real
/// tool. `pending` is the EXPLICIT set of not-yet-implemented tools — it landed
/// in Phase 1 with 60 entries, shrank to 40 when Phase 2's 20 reads landed,
/// then by Phase 3's 17 GuessWho-data writes, then by Phase 4's 22 Contact Store
/// writes, and reached empty at Phase 5 with the confirmation-gated
/// `contacts delete`. The guard is now STRICT: all 63 tools are registered, so
/// it proves full parity with `MCPTool.allCases` and catches any future drift —
/// a new tool without a command, a command without a tool, a non-derived name.
///
/// The field-level schema-parity check (§3.4) is `ContactScalarFieldParityTests`:
/// scoped to the contact scalar flags, the only large per-field surface.
final class ParityGuardTests: XCTestCase {

    /// The tools without a CLI command. Empty at Phase 5: every `MCPTool` case
    /// now has a registered command.
    static let pending: Set<MCPTool> = []

    /// The current expected size of `pending`. Phase 5 registers the last tool
    /// (the confirmation-gated delete), so full parity means zero pending.
    static let expectedPendingCount = 0

    func testPendingHasExpectedCount() {
        XCTAssertEqual(Self.pending.count, Self.expectedPendingCount)
    }

    /// tool → command: every non-pending tool has a registered command whose
    /// ACTUAL path in the tree equals the §2-derived path.
    func testEveryNonPendingToolHasACommandAtTheDerivedPath() {
        let registered = CLICommandRegistry.commandsByTool
        for tool in MCPTool.allCases where !Self.pending.contains(tool) {
            guard let command = registered[tool] else {
                XCTFail("\(tool.rawValue) has no CLI command")
                continue
            }
            let actual = CLICommandRegistry.actualPath(for: command)
            XCTAssertEqual(
                actual, CLICommandRegistry.derivedPath(for: tool),
                "\(tool.rawValue) command path drifted from the derivation rule")
        }
    }

    /// command → tool: the registered count equals all tools minus pending, so
    /// no tool is both pending and registered, and none is forgotten by both.
    func testRegisteredCountMatchesToolsMinusPending() {
        let registered = CLICommandRegistry.commandsByTool
        XCTAssertEqual(registered.count, MCPTool.allCases.count - Self.pending.count)
    }

    /// pending and registered are disjoint (no tool claimed twice, none in both
    /// buckets).
    func testPendingAndRegisteredAreDisjointAndComplete() {
        let registered = Set(CLICommandRegistry.commandsByTool.keys)
        XCTAssertTrue(registered.isDisjoint(with: Self.pending))
        XCTAssertEqual(registered.union(Self.pending), Set(MCPTool.allCases))
    }

    /// The derivation rule itself, on representative names (locks the rule
    /// before the commands that use it exist).
    func testDerivationRuleExamples() {
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .contactsSearch), "contacts search")
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .contactsGetPhoto), "contacts get-photo")
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .contactsSetPhoto), "contacts set-photo")
        XCTAssertEqual(
            CLICommandRegistry.derivedPath(for: .contactsListCustomFields),
            "contacts list-custom-fields")
        XCTAssertEqual(
            CLICommandRegistry.derivedPath(for: .organizationsListDepartmentMembers),
            "organizations list-department-members")
    }

    /// Every registered command's `tool` round-trips through the derived path
    /// (guards a command declaring a `tool` its name doesn't match).
    func testRegisteredCommandsSitAtTheirToolsDerivedPath() {
        for command in CLICommandRegistry.toolCommands {
            let actual = CLICommandRegistry.actualPath(for: command)
            XCTAssertEqual(actual, CLICommandRegistry.derivedPath(for: command.tool))
        }
    }
}
