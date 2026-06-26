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
    static func rows(existing contact: Contact, incoming profile: LinkedInProfile) -> [LinkedInDiffRow] {
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
        add(.location, "Location", nil, profile.location) // existing location is sidecar-only
        add(.about, "About", nil, profile.about)          // existing about is a sidecar note

        // Emails / websites are MERGED, never replaced: we only ever ADD values
        // the contact is missing, and never delete existing ones. The LEFT shows
        // the existing set; the RIGHT shows the full RESULTING set (existing +
        // additions) so the user sees the end state. The row appears only when
        // there's at least one new value to add.
        let existingEmails = contact.emailAddresses.map(\.value)
        let newEmails = additions(profile.contactInfo?.emails ?? [], notIn: existingEmails)
        if !newEmails.isEmpty {
            add(.emails, "Email",
                existingEmails.joined(separator: "\n"),
                (existingEmails + newEmails).joined(separator: "\n"))
        }

        let existingSites = contact.urlAddresses.map(\.value)
        let newSites = additions(profile.contactInfo?.websites ?? [], notIn: existingSites)
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

    /// The members of `incoming` that aren't already in `existing`
    /// (case-insensitive, trimmed), preserving incoming order and de-duped.
    private static func additions(_ incoming: [String], notIn existing: [String]) -> [String] {
        let have = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for value in incoming {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !have.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }
}
