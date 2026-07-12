import Foundation

/// Builds the pre-filled `Contact` seed the app hands to its new-contact
/// editor when a LinkedIn import matches no existing contact. The seed's
/// `localID` is empty, so the editor's normal Save path takes the adapter's
/// brand-new-contact branch — the import reuses the standard new-contact
/// editor rather than growing its own form.
///
/// Lives in `GuessWhoSync` (not the app target) for the same reason as
/// `ContactEditModel`: the profile→Contact mapping is pure data logic, so it
/// is exercisable from `GuessWhoSyncTests` without an app-target test bundle.
///
/// Only CNContact-representable fields go in the seed. The LinkedIn-only
/// extras (headline / about / location sidecar fields, and the photo) have no
/// editor row; the app attaches them AFTER the user saves, keyed on
/// re-matching the saved contact (see the scene delegate's
/// `finishLinkedInNewContact`).
public enum LinkedInContactSeed {
    public static func contact(from profile: LinkedInProfile) -> Contact {
        // Run the display name through Foundation's PersonNameComponents parse
        // strategy so given/middle/family land in the right fields (e.g.
        // "Lydia E. Kavraki" splits as given/middle/family). If the parser
        // throws on an unusual name, fall back to dropping the whole trimmed
        // string into `givenName` — same policy as the event-attendee seed.
        // A missing/empty name yields empty name fields: the editor still
        // opens (titled "New Contact") and the user types the name.
        let trimmedName = (profile.fullName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: PersonNameComponents?
        let givenFallback: String
        if trimmedName.isEmpty {
            parsed = nil
            givenFallback = ""
        } else {
            parsed = try? PersonNameComponents(trimmedName, strategy: .name)
            givenFallback = parsed == nil ? trimmedName : ""
        }

        let emails = uniqueTrimmed(profile.contactInfo?.emails ?? [], key: { $0.lowercased() })
        let phones = uniqueTrimmed(profile.contactInfo?.phones ?? [], key: phoneKey)
        let websites = uniqueTrimmed(profile.contactInfo?.websites ?? [], key: urlKey)

        // Contacts' LinkedIn social-profile field expects the USERNAME, not a
        // URL — it derives the URL from the username, and a stored URL shows
        // blank in the normal card view. Store just the slug (same convention
        // as `ContactsRepository.applyLinkedIn`). Seeding this also makes the
        // saved contact re-matchable by the post-save step and by any future
        // import of the same profile (URL tier).
        var socialProfiles: [LabeledSocialProfile] = []
        let profileURL = profile.contactInfo?.profileUrl ?? profile.sourceUrl
        // The `profile.slug` fallback gets the same trim + lowercase
        // normalization `LinkedInURL.slug(from:)` applies, so the seeded
        // username's canonical casing doesn't depend on which source won.
        let slug = profile.isRiceProfile ? "" : (
            profileURL.flatMap { LinkedInURL.slug(from: $0) }
                ?? profile.slug?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? ""
        )
        if !slug.isEmpty {
            socialProfiles.append(LabeledSocialProfile(
                label: "LinkedIn",
                value: SocialProfile(urlString: "", username: slug, service: "LinkedIn")
            ))
        }

        let emailAddresses = emails.map { LabeledValue(label: "", value: $0) }
        let phoneNumbers = phones.map { LabeledValue(label: "", value: $0) }
        var urlAddresses = websites.map { LabeledValue(label: "", value: $0) }
        urlAddresses += riceProfileWebsite(profile, excluding: websites)

        var contact = Contact()
        contact.namePrefix = parsed?.namePrefix ?? ""
        contact.givenName = parsed?.givenName ?? givenFallback
        contact.middleName = parsed?.middleName ?? ""
        contact.familyName = parsed?.familyName ?? ""
        contact.nameSuffix = parsed?.nameSuffix ?? ""
        contact.jobTitle = (profile.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        contact.organizationName = (profile.org ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // CNContact multi-values — default label (empty -> the adapter passes
        // nil, so Contacts assigns its own default). The Rice source URL is
        // the sole exception and carries its explicit "Rice" label.
        contact.emailAddresses = emailAddresses
        contact.phoneNumbers = phoneNumbers
        contact.urlAddresses = urlAddresses
        contact.socialProfiles = socialProfiles
        return contact
    }

    /// Trimmed, non-empty members of `values`, de-duped by `key` (first
    /// occurrence wins), preserving order and the original surface form.
    private static func uniqueTrimmed(_ values: [String], key: (String) -> String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(value)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(value)
        }
        return out
    }

    /// Scheme- and case-insensitive URL dedup key, ignoring a leading `www.`
    /// and trailing slashes — same normalization as the app's
    /// `LinkedInDiff.urlKey`, so the seed and the diff agree on which
    /// websites count as duplicates.
    private static func urlKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = t.range(of: "://") { t = String(t[range.upperBound...]) }
        if t.hasPrefix("www.") { t = String(t.dropFirst(4)) }
        while t.hasSuffix("/") { t = String(t.dropLast()) }
        return t
    }

    private static func phoneKey(_ s: String) -> String {
        s.filter(\.isNumber)
    }

    /// The source page itself is useful contact data, separate from the
    /// external websites listed on it. Rice explicitly owns this label.
    private static func riceProfileWebsite(_ profile: LinkedInProfile, excluding websites: [String]) -> [LabeledValue] {
        guard profile.isRiceProfile,
              let raw = profile.sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !websites.contains(where: { urlKey($0) == urlKey(raw) }) else { return [] }
        return [LabeledValue(label: "Rice", value: raw)]
    }
}
