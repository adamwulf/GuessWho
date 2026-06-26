import SwiftUI
import GuessWhoSync

struct ContactRow: View {
    let contact: Contact
    let hasGuessWhoUUID: Bool

    @AppStorage(AppSettings.Key.debugModeEnabled) private var debugModeEnabled = AppSettings.Default.debugModeEnabled

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(avatarColor)
                Text(contact.initials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                nameLabel
                    .font(.body)
                // Reserve a caption-sized second line on every row so
                // names with a subtitle and names without one occupy
                // the same vertical space — keeps the list rhythm even
                // when most contacts have no job/org info.
                subtitleLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if debugModeEnabled, hasGuessWhoUUID {
            Text("GuessWho ✓")
        } else if contact.contactType == .person, !contact.jobTitle.isEmpty || !contact.organizationName.isEmpty {
            Text(roleSubtitle)
        } else {
            // Empty space placeholder — keeps the row's two-line
            // height stable. `\u{00A0}` (non-breaking space) renders
            // an invisible character with the same line metrics as a
            // real caption, which a plain empty string does not.
            Text("\u{00A0}")
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

    private var avatarColor: Color {
        let seed = "\(contact.contactType)-\(contact.displayName)"
        let value = seed.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        let palette: [Color] = [
            .blue,
            .green,
            .indigo,
            .orange,
            .pink,
            .purple,
            .red,
            .teal,
        ]
        return palette[abs(value) % palette.count]
    }
}
