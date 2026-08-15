import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

/// The single-value contact scalar flags shared by `contacts create` and
/// `contacts update`. Both commands embed this via `@OptionGroup`, so the two
/// carry the IDENTICAL per-field surface: a new scalar is declared in one place
/// and the field-level parity guard (`ParityGuardTests`) checks the set against
/// `WireContactScalarFields` so a future wire field can't land without a flag.
///
/// Every flag is an optional string. An omitted flag stays out of the argument
/// bag entirely — the wire's PATCH rule, where an absent key leaves the field
/// untouched — and an explicit empty string is sent verbatim, which the server
/// treats as "clear this field". Each property is named for its wire bag key, so
/// ArgumentParser derives the kebab flag (`givenName` → `--given-name`) and that
/// same name is the bag key, keeping the two in lockstep.
public struct ContactScalarOptions: ParsableArguments {
    @Option(help: "person or organization.")
    public var kind: String?

    @Option(help: "Name prefix, e.g. Dr.")
    public var namePrefix: String?

    @Option(help: "Given (first) name.")
    public var givenName: String?

    @Option(help: "Middle name.")
    public var middleName: String?

    @Option(help: "Family (last) name.")
    public var familyName: String?

    @Option(help: "Previous family name, e.g. a maiden name.")
    public var previousFamilyName: String?

    @Option(help: "Name suffix, e.g. Jr.")
    public var nameSuffix: String?

    @Option(help: "Nickname.")
    public var nickname: String?

    @Option(help: "Phonetic spelling of the given name.")
    public var phoneticGivenName: String?

    @Option(help: "Phonetic spelling of the middle name.")
    public var phoneticMiddleName: String?

    @Option(help: "Phonetic spelling of the family name.")
    public var phoneticFamilyName: String?

    @Option(help: "Organization or company name.")
    public var organization: String?

    @Option(help: "Phonetic spelling of the organization name.")
    public var phoneticOrganization: String?

    @Option(help: "Department within the organization.")
    public var department: String?

    @Option(help: "Job title.")
    public var jobTitle: String?

    @Option(help: "Birthday as yyyy-MM-dd, or --MM-dd for no year.")
    public var birthday: String?

    public init() {}

    /// (bag key, value key path) for every scalar flag, in contact-card order.
    /// The single source both `assignScalars` and the field-parity guard read;
    /// it stays aligned with `WireContactScalarFields` (guarded by that test).
    static let scalarKeyPaths: [(key: String, path: KeyPath<ContactScalarOptions, String?>)] = [
        ("kind", \.kind),
        ("namePrefix", \.namePrefix),
        ("givenName", \.givenName),
        ("middleName", \.middleName),
        ("familyName", \.familyName),
        ("previousFamilyName", \.previousFamilyName),
        ("nameSuffix", \.nameSuffix),
        ("nickname", \.nickname),
        ("phoneticGivenName", \.phoneticGivenName),
        ("phoneticMiddleName", \.phoneticMiddleName),
        ("phoneticFamilyName", \.phoneticFamilyName),
        ("organization", \.organization),
        ("phoneticOrganization", \.phoneticOrganization),
        ("department", \.department),
        ("jobTitle", \.jobTitle),
        ("birthday", \.birthday),
    ]

    /// Copy every supplied scalar into `bag` under its wire key. An omitted flag
    /// (nil) is left out; an empty string is copied verbatim (clears the field).
    public func assignScalars(into bag: inout [String: Value]) {
        for (key, path) in Self.scalarKeyPaths {
            if let value = self[keyPath: path] { bag[key] = .string(value) }
        }
    }
}
