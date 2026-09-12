import Foundation

/// Candidate lists behind the contact editor's autocompleting fields. Each
/// returns the FULL candidate set for one field, de-duplicated and sorted;
/// the app narrows it against what the user has typed with
/// `TextSuggestionFilter`. Keeping the "what could be suggested" half here
/// (next to the cache it reads) and the "what matches" half in the filter
/// keeps both testable from `GuessWhoSyncTests` without a UI.
extension ContactsRepository {
    /// Display names for the Related field: every cached contact except
    /// `excludedID` (the contact being edited — a contact relating to itself
    /// is never useful), unnamed contacts skipped, de-duplicated
    /// case-insensitively (first spelling wins), sorted A–Z. Relations are
    /// matched back to contacts by display name (see `contacts(named:)`), so
    /// suggesting exactly those names guarantees an accepted suggestion
    /// resolves to a contact link on the card.
    public func relatedNameSuggestionCandidates(excluding excludedID: ContactID?) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for contact in contacts {
            if let excludedID, contact.contactID == excludedID { continue }
            let name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != Contact.unnamedDisplayName else { continue }
            guard seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Organization names for the Company field: every organization record's
    /// name plus every distinct company string carried by a person (a phantom
    /// organization — see `phantomOrganizations(matching:)`), collapsed
    /// case-insensitively and sorted A–Z. When a name exists both as a record
    /// and on people, the record's spelling wins; among people-only spellings
    /// the one that sorts first wins (a capitalized "Acme" over "acme"),
    /// mirroring the phantom projection.
    public func organizationNameSuggestionCandidates() -> [String] {
        var spellingByKey: [String: String] = [:]
        var recordKeys: Set<String> = []

        for contact in contacts where contact.contactType == .organization {
            let name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedOrgKey(name)
            guard !key.isEmpty, name != Contact.unnamedDisplayName else { continue }
            // First record with a given key keeps its spelling, like
            // `organizationContact(named:)` resolves ambiguity to the first.
            if recordKeys.insert(key).inserted {
                spellingByKey[key] = name
            }
        }

        for person in contacts where person.contactType == .person {
            let name = person.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedOrgKey(name)
            guard !key.isEmpty, !recordKeys.contains(key) else { continue }
            if let existing = spellingByKey[key] {
                if name < existing { spellingByKey[key] = name }
            } else {
                spellingByKey[key] = name
            }
        }

        return spellingByKey.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Department names for the Department field, scoped to the organization
    /// named `organizationName`: the distinct departments already used by the
    /// people associated with that organization (see
    /// `departments(inOrganizationNamed:)`). Empty when the organization is
    /// blank — a department is only meaningful inside an organization, so
    /// there is nothing to suggest until the Company field is filled in.
    public func departmentNameSuggestionCandidates(inOrganizationNamed organizationName: String) -> [String] {
        departments(inOrganizationNamed: organizationName)
    }
}
