import Foundation
import GuessWhoSync

extension Contact {
    /// User-facing display label. Falls back through given+family →
    /// organization → nickname → "(Unnamed)". Shared by every list row
    /// and detail header so the same contact never appears under
    /// different names across screens.
    var displayName: String {
        let personName = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
        if !personName.isEmpty { return personName }
        if !organizationName.isEmpty { return organizationName }
        if !nickname.isEmpty { return nickname }
        return "(Unnamed)"
    }
}
