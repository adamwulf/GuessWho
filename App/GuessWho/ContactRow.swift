import SwiftUI
import GuessWhoSync

struct ContactRow: View {
    let contact: Contact
    let hasGuessWhoUUID: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contact.contactType == .organization ? "building.2.crop.circle.fill" : "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                nameLabel
                    .font(.body)
                if hasGuessWhoUUID {
                    Text("GuessWho ✓")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if contact.contactType == .person, !contact.jobTitle.isEmpty || !contact.organizationName.isEmpty {
                    Text(roleSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var nameLabel: Text {
        let given = contact.givenName.trimmingCharacters(in: .whitespaces)
        let family = contact.familyName.trimmingCharacters(in: .whitespaces)
        if !given.isEmpty, !family.isEmpty {
            return Text(given + " ") + Text(family).fontWeight(.bold)
        }
        if !family.isEmpty {
            return Text(family).fontWeight(.bold)
        }
        if !given.isEmpty {
            return Text(given)
        }
        return Text(contact.displayName)
    }

    private var roleSubtitle: String {
        if !contact.jobTitle.isEmpty, !contact.organizationName.isEmpty {
            return "\(contact.jobTitle), \(contact.organizationName)"
        }
        if !contact.jobTitle.isEmpty { return contact.jobTitle }
        return contact.organizationName
    }
}
