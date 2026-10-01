import Foundation
import GuessWhoSync

extension Contact {
    /// The seed `Contact` handed to `ContactEditView(newContactSeed:)` for
    /// someone known only by an email address and, maybe, a display name — an
    /// event invitee or a Mail recipient. `localID` is empty so the adapter's
    /// save path takes the brand-new-contact branch.
    ///
    /// The display name is run through Foundation's `PersonNameComponents`
    /// parse strategy so prefix/given/middle/family/suffix all land in the
    /// right fields (e.g. "Dr. Jane Q. Doe Jr." splits correctly). When the
    /// name is missing or is just the email itself, the name fields stay
    /// empty rather than letting the parser shove the email into
    /// `givenName`. If the parser throws on an unusual display name, the
    /// trimmed string goes into `givenName`.
    static func newPersonSeed(name: String?, email: String) -> Contact {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: PersonNameComponents?
        let givenFallback: String
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(email) == .orderedSame {
            parsed = nil
            givenFallback = ""
        } else {
            parsed = try? PersonNameComponents(trimmed, strategy: .name)
            givenFallback = parsed == nil ? trimmed : ""
        }
        return Contact(
            namePrefix: parsed?.namePrefix ?? "",
            givenName: parsed?.givenName ?? givenFallback,
            middleName: parsed?.middleName ?? "",
            familyName: parsed?.familyName ?? "",
            nameSuffix: parsed?.nameSuffix ?? "",
            emailAddresses: [LabeledValue(label: "", value: email)]
        )
    }
}
