import Foundation
import GuessWhoSync

/// One field's before/after for the LinkedIn confirm dialog. Presentation-only
/// (app side) — the package owns matching, this owns how a match is shown and
/// which fields the user chose. Each row is independently includable.
struct LinkedInDiffRow: Identifiable {
    enum Field: String {
        case name, jobTitle, organization, location, about
        case emails, websites, linkedInURL, photo
    }

    let id: Field
    let label: String
    /// Existing value as a display string (nil/empty = contact has nothing).
    let existing: String?
    /// Incoming value from LinkedIn as a display string.
    let incoming: String?
    /// True when existing != incoming (drives prominent vs. de-emphasized).
    let changed: Bool
    /// Photo rows render thumbnails, not text.
    let isPhoto: Bool
}

/// Builds the ordered diff rows from a matched contact and the parsed profile.
/// Only includes a row when the profile actually carries that field (we never
/// show an incoming-empty row). Photo is always first when present.
enum LinkedInDiff {
    /// The sidecar field names `ContactsRepository.applyLinkedIn` writes the
    /// LinkedIn About / Location values to. The diff reads the SAME names so a
    /// re-import shows the contact's current value on the existing side.
    static let aboutFieldName = "LinkedIn About"
    static let locationFieldName = "LinkedIn Location"

    /// - Parameter existingSidecar: the contact's current sidecar field values
    ///   keyed by field name (e.g. `["LinkedIn About": "…", "LinkedIn Location":
    ///   "…"]`). About/Location aren't `CNContact` fields, so their existing
    ///   value lives here, not on `contact`. Pass `[:]` when the contact is
    ///   unreconciled (no sidecar fields yet) — every row then reads as new.
    static func rows(
        existing contact: Contact,
        incoming profile: LinkedInProfile,
        existingSidecar: [String: String] = [:]
    ) -> [LinkedInDiffRow] {
        var rows: [LinkedInDiffRow] = []

        func add(_ id: LinkedInDiffRow.Field, _ label: String, _ existing: String?, _ incoming: String?, isPhoto: Bool = false) {
            // Skip rows with no incoming value (nothing to sync).
            let inc = incoming?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPhoto || (inc != nil && !inc!.isEmpty) else { return }
            let ex = existing?.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = (ex ?? "") != (inc ?? "")
            rows.append(LinkedInDiffRow(
                id: id, label: label,
                existing: (ex?.isEmpty == false) ? ex : nil,
                incoming: (inc?.isEmpty == false) ? inc : nil,
                changed: changed, isPhoto: isPhoto
            ))
        }

        // Photo (rendered specially; existing/incoming carried by the view, not strings).
        if profile.photo != nil {
            rows.append(LinkedInDiffRow(
                id: .photo, label: "Photo",
                existing: contact.imageDataAvailable ? "current" : nil,
                incoming: "new",
                changed: true, isPhoto: true
            ))
        }

        let existingName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        add(.name, "Name", existingName, profile.fullName)
        add(.jobTitle, "Job title", contact.jobTitle, profile.title)
        add(.organization, "Organization", contact.organizationName, profile.org)
        // Location / About are sidecar-only (not CNContact fields). Read the
        // contact's current value from the named sidecar fields so a re-import
        // shows the existing value and marks the row unchanged when it matches.
        add(.location, "Location", existingSidecar[locationFieldName], profile.location)
        add(.about, "About", existingSidecar[aboutFieldName], profile.about)

        // Emails / websites are MERGED, never replaced: we only ever ADD values
        // the contact is missing, and never delete existing ones. The LEFT shows
        // the existing set; the RIGHT shows the full RESULTING set (existing +
        // additions) so the user sees the end state. The row appears only when
        // there's at least one new value to add.
        let existingEmails = contact.emailAddresses.map(\.value)
        let newEmails = additions(profile.contactInfo?.emails ?? [], notIn: existingEmails, key: plainKey)
        if !newEmails.isEmpty {
            add(.emails, "Email",
                existingEmails.joined(separator: "\n"),
                (existingEmails + newEmails).joined(separator: "\n"))
        }

        // Hide GuessWho's internal identity URL (guesswho://contact/<uuid>) from
        // the diff — it lives in urlAddresses but is sidecar plumbing the user
        // should never see.
        //
        // DISPLAY-ONLY: this filtered list is used only to render the row and to
        // compute which incoming sites are NEW. The save step MUST merge new
        // websites onto the contact's REAL urlAddresses (which still contains the
        // guesswho:// identity URL) and never reconstruct urlAddresses from this
        // filtered set — dropping the identity URL would orphan the contact's
        // sidecar data. The filter affects pixels, not stored data.
        let existingSites = contact.urlAddresses.map(\.value)
            .filter { !$0.hasPrefix(SidecarKey.guessWhoContactURLPrefix) }
        // URL dedup is scheme-insensitive: "adamwulf.me" already on the contact
        // matches LinkedIn's "https://adamwulf.me", so it isn't added again.
        let newSites = additions(profile.contactInfo?.websites ?? [], notIn: existingSites, key: urlKey)
        if !newSites.isEmpty {
            add(.websites, "Websites",
                existingSites.joined(separator: "\n"),
                (existingSites + newSites).joined(separator: "\n"))
        }

        // LinkedIn URL: add only if the contact has no LinkedIn social profile yet.
        if let url = profile.contactInfo?.profileUrl ?? profile.sourceUrl {
            let existingLinkedIn = contact.socialProfiles
                .first { LinkedInURL.isLinkedIn($0.value.urlString) }?.value.urlString
            let alreadyHas = existingLinkedIn.map { LinkedInURL.sameProfile($0, url) } ?? false
            if !alreadyHas {
                add(.linkedInURL, "LinkedIn", existingLinkedIn, url)
            }
        }

        return rows
    }

    /// The members of `incoming` that aren't already in `existing`, comparing by
    /// `key` (so different surface forms of the same value dedup together),
    /// preserving incoming order and the original incoming text.
    private static func additions(
        _ incoming: [String],
        notIn existing: [String],
        key: (String) -> String
    ) -> [String] {
        let have = Set(existing.map(key))
        var seen = Set<String>()
        var out: [String] = []
        for value in incoming {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(trimmed)
            guard !k.isEmpty, !have.contains(k), !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(trimmed)
        }
        return out
    }

    /// Plain case-insensitive key (emails).
    private static func plainKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// URL dedup key: scheme- and case-insensitive, ignoring a leading `www.`
    /// and a trailing slash. So "adamwulf.me", "http://adamwulf.me",
    /// "https://www.adamwulf.me/" all collapse to the same key — a contact's
    /// bare URL is recognized as the same as LinkedIn's https one.
    private static func urlKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = t.range(of: "://") { t = String(t[range.upperBound...]) }
        if t.hasPrefix("www.") { t = String(t.dropFirst(4)) }
        while t.hasSuffix("/") { t = String(t.dropLast()) }
        return t
    }
}
