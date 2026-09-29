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
