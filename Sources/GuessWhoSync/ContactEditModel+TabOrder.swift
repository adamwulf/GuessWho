import Foundation

extension ContactEditModel {
    /// One text field of the contact editor — a stop of its Tab order. A
    /// field of a multi-value row carries the index of its entry in that
    /// row's list (`phone(1)` is the second phone number).
    public enum Field: Hashable, Sendable {
        case namePrefix, givenName, middleName, familyName, nameSuffix, nickname
        case organizationName, departmentName, jobTitle
        case phone(Int)
        case email(Int)
        case url(Int)
        case street(Int), city(Int), state(Int), postalCode(Int), country(Int)
        case relation(Int)
        case socialProfile(Int)
        case instantMessage(Int)
        case phoneticGivenName, phoneticMiddleName, phoneticFamilyName
        case note
    }

    /// The editor's text fields in on-screen order: the order Tab moves
    /// through them. It must list the fields in the same order as the
    /// editor's rows draw them (`ContactEditorSections` in the app).
    ///
    /// Only text fields are stops. The label menus, toggles, date pickers,
    /// and buttons between them are skipped, the same as Tab in Contacts on
    /// the Mac and in a form on iPad.
    ///
    /// `includingPhoneticName` is false while the Phonetic Name group is
    /// collapsed: its fields are not on screen then, so Tab must not go to
    /// them.
    public func tabOrder(includingPhoneticName: Bool) -> [Field] {
        var order: [Field] = [
            .namePrefix, .givenName, .middleName, .familyName, .nameSuffix, .nickname,
            .organizationName, .departmentName, .jobTitle,
        ]
        order += edited.phoneNumbers.indices.map(Field.phone)
        order += edited.emailAddresses.indices.map(Field.email)
        order += visibleURLAddresses.indices.map(Field.url)
        for index in edited.postalAddresses.indices {
            order += [.street(index), .city(index), .state(index), .postalCode(index), .country(index)]
        }
        order += edited.contactRelations.indices.map(Field.relation)
        order += edited.socialProfiles.indices.map(Field.socialProfile)
        order += edited.instantMessageAddresses.indices.map(Field.instantMessage)
        if includingPhoneticName {
            order += [.phoneticGivenName, .phoneticMiddleName, .phoneticFamilyName]
        }
        order.append(.note)
        return order
    }

    /// The field Tab moves to from `field`: the next one in `tabOrder`, or
    /// the previous one when `backward` (Shift-Tab). It wraps at both ends,
    /// so Tab never leaves the editor. A field that is not in the order
    /// (nil, or a field whose entry was just removed) moves to the first
    /// field, or to the last one when going backward.
    public func tabStop(
        from field: Field?,
        backward: Bool,
        includingPhoneticName: Bool
    ) -> Field {
        // Never empty: the name fields are always in it.
        let order = tabOrder(includingPhoneticName: includingPhoneticName)
        guard let field, let index = order.firstIndex(of: field) else {
            return backward ? order[order.count - 1] : order[0]
        }
        let step = backward ? order.count - 1 : 1
        return order[(index + step) % order.count]
    }
}
