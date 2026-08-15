import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// The field-level parity guard (§3.4), scoped — per the plan — to the contact
/// scalar flags, the one place with a large per-field surface that can drift
/// against the wire schema. It checks that every `WireContactScalarFields`
/// property is reachable as a flag on BOTH `contacts create` and
/// `contacts update`, and that no flag names a property the wire doesn't have,
/// so a future scalar landing on the wire without a CLI flag fails here.
final class ContactScalarFieldParityTests: XCTestCase {

    /// The scalar property names the wire declares, read from the struct itself
    /// (Mirror reflects only stored properties, so the computed helpers on
    /// `WireContactScalarFields` are excluded).
    private static var wireScalarKeys: Set<String> {
        Set(Mirror(reflecting: WireContactScalarFields()).children.compactMap { $0.label })
    }

    /// The bag keys the shared `ContactScalarOptions` maps, in one place.
    private static var flagKeys: Set<String> {
        Set(ContactScalarOptions.scalarKeyPaths.map(\.key))
    }

    func testFlagKeysMatchWireScalarFieldsExactly() {
        XCTAssertEqual(
            Self.flagKeys, Self.wireScalarKeys,
            "contacts create/update scalar flags drifted from WireContactScalarFields — add or remove the matching flag")
    }

    func testEveryScalarFieldParsesAndMapsOnBothCommands() {
        for key in Self.wireScalarKeys {
            let flag = "--" + Self.kebab(key)
            do {
                let update = try ContactsUpdate.parse(["c1", flag, "sentinel"])
                XCTAssertEqual(
                    try update.argumentBag()[key], .string("sentinel"),
                    "contacts update: \(flag) does not map to bag key \(key)")

                let create = try ContactsCreate.parse([flag, "sentinel"])
                XCTAssertEqual(
                    try create.argumentBag()[key], .string("sentinel"),
                    "contacts create: \(flag) does not map to bag key \(key)")
            } catch {
                XCTFail("\(flag) is not a valid flag on both contacts create and contacts update: \(error)")
            }
        }
    }

    /// camelCase → kebab-case, matching ArgumentParser's default long-name
    /// derivation for these simple (no consecutive-caps) property names.
    static func kebab(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                result += "-"
                result += character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }
}
