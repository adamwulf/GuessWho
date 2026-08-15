import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP

// MARK: - Object builders

/// Assembles the typed structured-entry objects (postal address, social
/// profile, instant-message address) the wire's `WireRequest.create` decodes
/// under a schema key. Each builder mirrors that decoder's shape exactly, so
/// the object a flag group produces is byte-for-byte what an equivalent `--json`
/// payload would produce, and the server stays the single validator.
enum CLIStructuredEntry {
    /// A postal address object. The five wire-required components
    /// (street/city/state/postalCode/country) default to the empty string when
    /// their flag is omitted, so copying a partial address out of `contacts get`
    /// stays lossless; the server enforces the "at least one component non-empty"
    /// rule. The four optional components appear only when supplied.
    static func postal(
        label: String?, street: String?, subLocality: String?, city: String?,
        subAdministrativeArea: String?, state: String?, postalCode: String?,
        country: String?, isoCountryCode: String?
    ) -> Value {
        var object: [String: Value] = [
            "street": .string(street ?? ""),
            "city": .string(city ?? ""),
            "state": .string(state ?? ""),
            "postalCode": .string(postalCode ?? ""),
            "country": .string(country ?? ""),
        ]
        put(&object, "label", label)
        put(&object, "subLocality", subLocality)
        put(&object, "subAdministrativeArea", subAdministrativeArea)
        put(&object, "isoCountryCode", isoCountryCode)
        return .object(object)
    }

    /// A social-profile object. Every component is optional on the wire, so only
    /// the supplied ones appear; the server enforces "at least one of service,
    /// username, or url non-empty".
    static func social(label: String?, service: String?, username: String?, url: String?) -> Value {
        var object: [String: Value] = [:]
        put(&object, "label", label)
        put(&object, "service", service)
        put(&object, "username", username)
        put(&object, "url", url)
        return .object(object)
    }

    /// An instant-message object. Only supplied components appear; the server
    /// enforces the non-empty username.
    static func instantMessage(label: String?, service: String?, username: String?) -> Value {
        var object: [String: Value] = [:]
        put(&object, "label", label)
        put(&object, "service", service)
        put(&object, "username", username)
        return .object(object)
    }

    private static func put(_ object: inout [String: Value], _ key: String, _ value: String?) {
        if let value { object[key] = .string(value) }
    }
}

// MARK: - Structured-entry argument merge

/// Place a single structured entry into `bag` under `key`. The per-field flag
/// object (non-nil only when at least one field flag was passed) goes in first;
/// the optional `--json` payload merges next and conflicts on the same key, so
/// giving both a flag and `--json` is a usage error, never a silent merge.
func assignStructuredEntry(
    _ key: String, flagObject: Value?, json: String?, jsonFile: String?,
    into bag: inout [String: Value]
) throws {
    if let flagObject { bag[key] = flagObject }
    if let payload = try CLIJSONInput.read(inline: json, file: jsonFile) {
        try CLIJSONInput.assign(payload, toKey: key, in: &bag)
    }
}

/// Place a structured-entry edit's current/new pair into `bag`. Per-field flag
/// objects (each non-nil only when its group has a flag) go in first; the
/// `--json` pair object merges next, conflicting on either key.
func assignStructuredEditPair(
    currentKey: String, currentObject: Value?, newKey: String, newObject: Value?,
    json: String?, jsonFile: String?, into bag: inout [String: Value]
) throws {
    if let currentObject { bag[currentKey] = currentObject }
    if let newObject { bag[newKey] = newObject }
    if let payload = try CLIJSONInput.read(inline: json, file: jsonFile) {
        guard case .object(let pair) = payload else {
            throw CLIUsageError("The --json value must be a JSON object with the current and new entry.")
        }
        for (key, value) in pair {
            try CLIJSONInput.assign(value, toKey: key, in: &bag)
        }
    }
}

// MARK: - Per-field help (shared across the add/delete and current/new groups)

private enum PostalFieldHelp {
    static let label = "Optional label, e.g. home or work."
    static let street = "Street address."
    static let subLocality = "Neighborhood or sub-locality."
    static let city = "City."
    static let subAdministrativeArea = "County or sub-administrative area."
    static let state = "State or province."
    static let postalCode = "Postal or ZIP code."
    static let country = "Country name."
    static let isoCountryCode = "ISO country code, e.g. us."
}

private enum SocialFieldHelp {
    static let label = "Optional label."
    static let service = "Service name, e.g. LinkedIn."
    static let username = "Username on that service."
    static let url = "Profile web address."
}

private enum InstantMessageFieldHelp {
    static let label = "Optional label."
    static let service = "Messaging service name."
    static let username = "Username on that service."
}

// MARK: - Postal option groups

/// The `--label --street …` flags for postal add/delete.
public struct PostalEntryOptions: ParsableArguments {
    @Option(help: ArgumentHelp(PostalFieldHelp.label)) public var label: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.street)) public var street: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.subLocality)) public var subLocality: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.city)) public var city: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.subAdministrativeArea)) public var subAdministrativeArea: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.state)) public var state: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.postalCode)) public var postalCode: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.country)) public var country: String?
    @Option(help: ArgumentHelp(PostalFieldHelp.isoCountryCode)) public var isoCountryCode: String?

    public init() {}

    private var allFields: [String?] {
        [label, street, subLocality, city, subAdministrativeArea, state, postalCode, country, isoCountryCode]
    }

    /// The address object, or nil when no field flag was passed (so `--json`
    /// can supply the entry instead).
    func objectIfAny() -> Value? {
        guard allFields.contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.postal(
            label: label, street: street, subLocality: subLocality, city: city,
            subAdministrativeArea: subAdministrativeArea, state: state,
            postalCode: postalCode, country: country, isoCountryCode: isoCountryCode)
    }
}

/// The `--current-label --current-street …` flags for postal edit.
public struct PostalCurrentOptions: ParsableArguments {
    @Option(name: .customLong("current-label"), help: ArgumentHelp(PostalFieldHelp.label)) public var label: String?
    @Option(name: .customLong("current-street"), help: ArgumentHelp(PostalFieldHelp.street)) public var street: String?
    @Option(name: .customLong("current-sub-locality"), help: ArgumentHelp(PostalFieldHelp.subLocality)) public var subLocality: String?
    @Option(name: .customLong("current-city"), help: ArgumentHelp(PostalFieldHelp.city)) public var city: String?
    @Option(name: .customLong("current-sub-administrative-area"), help: ArgumentHelp(PostalFieldHelp.subAdministrativeArea)) public var subAdministrativeArea: String?
    @Option(name: .customLong("current-state"), help: ArgumentHelp(PostalFieldHelp.state)) public var state: String?
    @Option(name: .customLong("current-postal-code"), help: ArgumentHelp(PostalFieldHelp.postalCode)) public var postalCode: String?
    @Option(name: .customLong("current-country"), help: ArgumentHelp(PostalFieldHelp.country)) public var country: String?
    @Option(name: .customLong("current-iso-country-code"), help: ArgumentHelp(PostalFieldHelp.isoCountryCode)) public var isoCountryCode: String?

    public init() {}

    private var allFields: [String?] {
        [label, street, subLocality, city, subAdministrativeArea, state, postalCode, country, isoCountryCode]
    }

    func objectIfAny() -> Value? {
        guard allFields.contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.postal(
            label: label, street: street, subLocality: subLocality, city: city,
            subAdministrativeArea: subAdministrativeArea, state: state,
            postalCode: postalCode, country: country, isoCountryCode: isoCountryCode)
    }
}

/// The `--new-label --new-street …` flags for postal edit.
public struct PostalNewOptions: ParsableArguments {
    @Option(name: .customLong("new-label"), help: ArgumentHelp(PostalFieldHelp.label)) public var label: String?
    @Option(name: .customLong("new-street"), help: ArgumentHelp(PostalFieldHelp.street)) public var street: String?
    @Option(name: .customLong("new-sub-locality"), help: ArgumentHelp(PostalFieldHelp.subLocality)) public var subLocality: String?
    @Option(name: .customLong("new-city"), help: ArgumentHelp(PostalFieldHelp.city)) public var city: String?
    @Option(name: .customLong("new-sub-administrative-area"), help: ArgumentHelp(PostalFieldHelp.subAdministrativeArea)) public var subAdministrativeArea: String?
    @Option(name: .customLong("new-state"), help: ArgumentHelp(PostalFieldHelp.state)) public var state: String?
    @Option(name: .customLong("new-postal-code"), help: ArgumentHelp(PostalFieldHelp.postalCode)) public var postalCode: String?
    @Option(name: .customLong("new-country"), help: ArgumentHelp(PostalFieldHelp.country)) public var country: String?
    @Option(name: .customLong("new-iso-country-code"), help: ArgumentHelp(PostalFieldHelp.isoCountryCode)) public var isoCountryCode: String?

    public init() {}

    private var allFields: [String?] {
        [label, street, subLocality, city, subAdministrativeArea, state, postalCode, country, isoCountryCode]
    }

    func objectIfAny() -> Value? {
        guard allFields.contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.postal(
            label: label, street: street, subLocality: subLocality, city: city,
            subAdministrativeArea: subAdministrativeArea, state: state,
            postalCode: postalCode, country: country, isoCountryCode: isoCountryCode)
    }
}

// MARK: - Social option groups

/// The `--label --service --username --url` flags for social add/delete.
public struct SocialEntryOptions: ParsableArguments {
    @Option(help: ArgumentHelp(SocialFieldHelp.label)) public var label: String?
    @Option(help: ArgumentHelp(SocialFieldHelp.service)) public var service: String?
    @Option(help: ArgumentHelp(SocialFieldHelp.username)) public var username: String?
    @Option(help: ArgumentHelp(SocialFieldHelp.url)) public var url: String?

    public init() {}

    func objectIfAny() -> Value? {
        guard [label, service, username, url].contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.social(label: label, service: service, username: username, url: url)
    }
}

/// The `--current-*` flags for social edit.
public struct SocialCurrentOptions: ParsableArguments {
    @Option(name: .customLong("current-label"), help: ArgumentHelp(SocialFieldHelp.label)) public var label: String?
    @Option(name: .customLong("current-service"), help: ArgumentHelp(SocialFieldHelp.service)) public var service: String?
    @Option(name: .customLong("current-username"), help: ArgumentHelp(SocialFieldHelp.username)) public var username: String?
    @Option(name: .customLong("current-url"), help: ArgumentHelp(SocialFieldHelp.url)) public var url: String?

    public init() {}

    func objectIfAny() -> Value? {
        guard [label, service, username, url].contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.social(label: label, service: service, username: username, url: url)
    }
}

/// The `--new-*` flags for social edit.
public struct SocialNewOptions: ParsableArguments {
    @Option(name: .customLong("new-label"), help: ArgumentHelp(SocialFieldHelp.label)) public var label: String?
    @Option(name: .customLong("new-service"), help: ArgumentHelp(SocialFieldHelp.service)) public var service: String?
    @Option(name: .customLong("new-username"), help: ArgumentHelp(SocialFieldHelp.username)) public var username: String?
    @Option(name: .customLong("new-url"), help: ArgumentHelp(SocialFieldHelp.url)) public var url: String?

    public init() {}

    func objectIfAny() -> Value? {
        guard [label, service, username, url].contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.social(label: label, service: service, username: username, url: url)
    }
}

// MARK: - Instant-message option groups

/// The `--label --service --username` flags for instant-message add/delete.
public struct InstantMessageEntryOptions: ParsableArguments {
    @Option(help: ArgumentHelp(InstantMessageFieldHelp.label)) public var label: String?
    @Option(help: ArgumentHelp(InstantMessageFieldHelp.service)) public var service: String?
    @Option(help: ArgumentHelp(InstantMessageFieldHelp.username)) public var username: String?

    public init() {}

    func objectIfAny() -> Value? {
        guard [label, service, username].contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.instantMessage(label: label, service: service, username: username)
    }
}

/// The `--current-*` flags for instant-message edit.
public struct InstantMessageCurrentOptions: ParsableArguments {
    @Option(name: .customLong("current-label"), help: ArgumentHelp(InstantMessageFieldHelp.label)) public var label: String?
    @Option(name: .customLong("current-service"), help: ArgumentHelp(InstantMessageFieldHelp.service)) public var service: String?
    @Option(name: .customLong("current-username"), help: ArgumentHelp(InstantMessageFieldHelp.username)) public var username: String?

    public init() {}

    func objectIfAny() -> Value? {
        guard [label, service, username].contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.instantMessage(label: label, service: service, username: username)
    }
}

/// The `--new-*` flags for instant-message edit.
public struct InstantMessageNewOptions: ParsableArguments {
    @Option(name: .customLong("new-label"), help: ArgumentHelp(InstantMessageFieldHelp.label)) public var label: String?
    @Option(name: .customLong("new-service"), help: ArgumentHelp(InstantMessageFieldHelp.service)) public var service: String?
    @Option(name: .customLong("new-username"), help: ArgumentHelp(InstantMessageFieldHelp.username)) public var username: String?

    public init() {}

    func objectIfAny() -> Value? {
        guard [label, service, username].contains(where: { $0 != nil }) else { return nil }
        return CLIStructuredEntry.instantMessage(label: label, service: service, username: username)
    }
}

// MARK: - Postal commands

/// `contacts add-postal-address` → `contacts_add_postal_address`. Give the
/// address with the per-field flags, or with a JSON object via `--json`. The
/// updated card echoes back as JSON.
public struct ContactsAddPostalAddress: CLIToolCommand {
    public static let tool: MCPTool = .contactsAddPostalAddress

    public static let configuration = CommandConfiguration(
        commandName: "add-postal-address",
        abstract: "Add one postal address to a contact. Give at least one component; the rest may be omitted."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var address: PostalEntryOptions

    @Option(help: "Give the address as a JSON object instead of the per-field flags. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the address JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried add apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEntry(
            "address", flagObject: address.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-postal-address` → `contacts_delete_postal_address`. Deletes
/// the entry that matches the complete address exactly. Copy the full entry from
/// `contacts get` (with the per-field flags or `--json`). The updated card
/// echoes back.
public struct ContactsDeletePostalAddress: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeletePostalAddress

    public static let configuration = CommandConfiguration(
        commandName: "delete-postal-address",
        abstract: "Delete one postal address from a contact, matched by its complete value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var address: PostalEntryOptions

    @Option(help: "Give the address as a JSON object instead of the per-field flags. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the address JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEntry(
            "address", flagObject: address.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts edit-postal-address` → `contacts_edit_postal_address`. Supply the
/// current entry (the exact match) and the new entry. The `--json` pair
/// `{"currentAddress":…,"newAddress":…}` is the primary path — copy the current
/// entry from `contacts get`; the `--current-*` / `--new-*` flags are the
/// alternative. The updated card echoes back.
public struct ContactsEditPostalAddress: CLIToolCommand {
    public static let tool: MCPTool = .contactsEditPostalAddress

    public static let configuration = CommandConfiguration(
        commandName: "edit-postal-address",
        abstract: "Replace one postal address on a contact, matched by its complete current value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var current: PostalCurrentOptions
    @OptionGroup public var new: PostalNewOptions

    @Option(help: "Both entries as JSON: {\"currentAddress\":{…},\"newAddress\":{…}}. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the pair JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried edit apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEditPair(
            currentKey: "currentAddress", currentObject: current.objectIfAny(),
            newKey: "newAddress", newObject: new.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

// MARK: - Social commands

/// `contacts add-social-profile` → `contacts_add_social_profile`. Give the
/// profile with the per-field flags or `--json`. The updated card echoes back.
public struct ContactsAddSocialProfile: CLIToolCommand {
    public static let tool: MCPTool = .contactsAddSocialProfile

    public static let configuration = CommandConfiguration(
        commandName: "add-social-profile",
        abstract: "Add one social profile to a contact. Give at least a service, username, or url."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var profile: SocialEntryOptions

    @Option(help: "Give the profile as a JSON object instead of the per-field flags. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the profile JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried add apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEntry(
            "profile", flagObject: profile.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-social-profile` → `contacts_delete_social_profile`. Deletes
/// the entry that matches the complete profile exactly. The updated card echoes
/// back.
public struct ContactsDeleteSocialProfile: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeleteSocialProfile

    public static let configuration = CommandConfiguration(
        commandName: "delete-social-profile",
        abstract: "Delete one social profile from a contact, matched by its complete value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var profile: SocialEntryOptions

    @Option(help: "Give the profile as a JSON object instead of the per-field flags. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the profile JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEntry(
            "profile", flagObject: profile.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts edit-social-profile` → `contacts_edit_social_profile`. The `--json`
/// pair `{"currentProfile":…,"newProfile":…}` is the primary path; the
/// `--current-*` / `--new-*` flags are the alternative. The updated card echoes
/// back.
public struct ContactsEditSocialProfile: CLIToolCommand {
    public static let tool: MCPTool = .contactsEditSocialProfile

    public static let configuration = CommandConfiguration(
        commandName: "edit-social-profile",
        abstract: "Replace one social profile on a contact, matched by its complete current value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var current: SocialCurrentOptions
    @OptionGroup public var new: SocialNewOptions

    @Option(help: "Both entries as JSON: {\"currentProfile\":{…},\"newProfile\":{…}}. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the pair JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried edit apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEditPair(
            currentKey: "currentProfile", currentObject: current.objectIfAny(),
            newKey: "newProfile", newObject: new.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

// MARK: - Instant-message commands

/// `contacts add-instant-message` → `contacts_add_instant_message`. Give the
/// entry with the per-field flags or `--json`. The updated card echoes back.
public struct ContactsAddInstantMessage: CLIToolCommand {
    public static let tool: MCPTool = .contactsAddInstantMessage

    public static let configuration = CommandConfiguration(
        commandName: "add-instant-message",
        abstract: "Add one instant-message address to a contact. A username is required."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var instantMessage: InstantMessageEntryOptions

    @Option(help: "Give the entry as a JSON object instead of the per-field flags. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the entry JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried add apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEntry(
            "instantMessage", flagObject: instantMessage.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts delete-instant-message` → `contacts_delete_instant_message`.
/// Deletes the entry that matches exactly. The updated card echoes back.
public struct ContactsDeleteInstantMessage: CLIToolCommand {
    public static let tool: MCPTool = .contactsDeleteInstantMessage

    public static let configuration = CommandConfiguration(
        commandName: "delete-instant-message",
        abstract: "Delete one instant-message address from a contact, matched by its complete value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var instantMessage: InstantMessageEntryOptions

    @Option(help: "Give the entry as a JSON object instead of the per-field flags. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the entry JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried delete apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEntry(
            "instantMessage", flagObject: instantMessage.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}

/// `contacts edit-instant-message` → `contacts_edit_instant_message`. The
/// `--json` pair `{"currentInstantMessage":…,"newInstantMessage":…}` is the
/// primary path; the `--current-*` / `--new-*` flags are the alternative. The
/// updated card echoes back.
public struct ContactsEditInstantMessage: CLIToolCommand {
    public static let tool: MCPTool = .contactsEditInstantMessage

    public static let configuration = CommandConfiguration(
        commandName: "edit-instant-message",
        abstract: "Replace one instant-message address on a contact, matched by its complete current value."
    )

    @Argument(help: "Contact id returned by contacts search or contacts list.")
    public var contactId: String

    @OptionGroup public var current: InstantMessageCurrentOptions
    @OptionGroup public var new: InstantMessageNewOptions

    @Option(help: "Both entries as JSON: {\"currentInstantMessage\":{…},\"newInstantMessage\":{…}}. Use '-' to read from stdin.")
    public var json: String?

    @Option(help: "Read the pair JSON from this file instead of --json.")
    public var jsonFile: String?

    @Option(help: "Token that makes a retried edit apply only once.")
    public var idempotencyToken: String?

    public init() {}

    public func argumentBag() throws -> [String: Value] {
        var bag: [String: Value] = ["contactId": .string(contactId)]
        try assignStructuredEditPair(
            currentKey: "currentInstantMessage", currentObject: current.objectIfAny(),
            newKey: "newInstantMessage", newObject: new.objectIfAny(),
            json: json, jsonFile: jsonFile, into: &bag)
        if let idempotencyToken { bag["idempotencyToken"] = .string(idempotencyToken) }
        return bag
    }
}
