import Foundation

extension Contact {
    /// Case-insensitive substring match across every field a user would
    /// reasonably search to find a contact: every name component, the
    /// organization/department/job, and the raw values of every email,
    /// phone number, and URL.
    ///
    /// Whitespace-only queries match every contact (treated as no filter).
    /// Used by the UI layer to filter the People and Organizations tabs.
    public func matches(searchQuery query: String) -> Bool {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if needle.isEmpty { return true }

        let scalarFields: [String] = [
            namePrefix, givenName, middleName,
            familyName, previousFamilyName, nameSuffix,
            nickname, phoneticGivenName, phoneticMiddleName,
            phoneticFamilyName,
            jobTitle, departmentName,
            organizationName, phoneticOrganizationName,
        ]
        for hay in scalarFields where hay.lowercased().contains(needle) {
            return true
        }
        for labeled in emailAddresses where labeled.value.lowercased().contains(needle) {
            return true
        }
        for labeled in phoneNumbers where labeled.value.lowercased().contains(needle) {
            return true
        }
        for labeled in urlAddresses where labeled.value.lowercased().contains(needle) {
            return true
        }
        return false
    }
}
