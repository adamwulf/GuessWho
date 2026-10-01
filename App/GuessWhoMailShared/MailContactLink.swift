import Foundation

/// The wake URL the Mail extension opens to show one contact in the app:
/// `<app wake scheme>://open-contact?id=<GuessWho ID>`.
///
/// The extension builds it and the app parses it, so both share this one
/// definition. The scheme is the app's per-configuration wake scheme
/// (`guesswho-linkedin[-debug]`), which each target reads from its own
/// Info.plist. The ID is the bare UUID from the contact's
/// `guesswho://contact/<uuid>` URL, never a Contacts identifier.
enum MailContactLink {
    static let host = "open-contact"
    private static let idParameter = "id"

    /// The URL for `contactID`, or nil when it is not a UUID.
    static func url(scheme: String, contactID: String) -> URL? {
        guard let uuid = UUID(uuidString: contactID) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: idParameter, value: uuid.uuidString.lowercased())]
        return components.url
    }

    /// The lowercase GuessWho ID in `url`, or nil when `url` is not an
    /// open-contact URL for `scheme` or its ID is not a UUID.
    static func contactID(from url: URL, scheme: String) -> String? {
        guard url.scheme == scheme, url.host == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == idParameter })?.value,
              let uuid = UUID(uuidString: raw)
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}

/// The wake URL the Mail extension opens to add a recipient the contact cache
/// doesn't know:
/// `<app wake scheme>://new-contact?email=<address>[&name=<display name>]`.
///
/// The app answers with a new-contact editor pre-filled with the address and
/// name. The extension builds the URL and the app parses it, with the same
/// scheme as `MailContactLink`. Any app on the Mac can open the URL, so the
/// parser treats every value as untrusted: it normalizes the address again
/// and applies the name rules again. That is enough, because the values only
/// pre-fill an editor the user must save.
enum MailNewContactLink {
    static let host = "new-contact"
    private static let emailParameter = "email"
    private static let nameParameter = "name"

    /// The longest name carried, in UTF-8 bytes. The name comes from a
    /// header the sender controls, so it is bounded in bytes, like the
    /// journal's subject (`MailIncomingMessage.clipped(_:toUTF8Length:)`): a
    /// longer name is cut at the last whole character that fits.
    static let maximumNameUTF8Length = 256

    /// What a new-contact URL asks for.
    struct Request: Equatable {
        /// The normalized (`MailAddressNormalizer`) address.
        let email: String
        /// The trimmed, bounded display name; nil when there is none.
        let name: String?
    }

    /// The URL that adds `email`, with `name` when it is usable, or nil when
    /// `email` is not an address. The URL carries the normalized address.
    static func url(scheme: String, email: String, name: String?) -> URL? {
        guard let address = MailAddressNormalizer.normalize(email) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var queryItems = [URLQueryItem(name: emailParameter, value: address)]
        if let name = usableName(name, email: address) {
            queryItems.append(URLQueryItem(name: nameParameter, value: name))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// The request in `url`, or nil when `url` is not a new-contact URL for
    /// `scheme` or its email is not an address.
    static func request(from url: URL, scheme: String) -> Request? {
        guard url.scheme == scheme, url.host == host,
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = queryItems.first(where: { $0.name == emailParameter })?.value,
              let address = MailAddressNormalizer.normalize(raw)
        else { return nil }
        let name = queryItems.first(where: { $0.name == nameParameter })?.value
        return Request(email: address, name: usableName(name, email: address))
    }

    /// `name` trimmed and cut to `maximumNameUTF8Length`, or nil when it is
    /// empty or is only the address again.
    private static func usableName(_ name: String?, email: String) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(email) != .orderedSame,
              let clipped = MailIncomingMessage.clipped(trimmed, toUTF8Length: maximumNameUTF8Length)
        else { return nil }
        let result = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
