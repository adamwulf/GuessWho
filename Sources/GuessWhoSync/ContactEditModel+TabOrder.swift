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
        /// The text field that shows an entry's label in place of the label
        /// menu, when the label is "other" or one the user typed.
        case phoneLabel(Int), emailLabel(Int), urlLabel(Int), addressLabel(Int), dateLabel(Int), relationLabel(Int)
    }

    /// The editor's text fields in on-screen order: the order Tab moves
    /// through them. It must list the fields in the same order as the
    /// editor's rows draw them (`ContactEditorSections` in the app).
    ///
    /// Only text fields are stops. The label menus, toggles, date pickers,
    /// and buttons between them are skipped, the same as Tab in Contacts on
    /// the Mac and in a form on iPad. A label shown as a text field instead
    /// of a menu is a stop, just before its entry's value field (a date has
    /// no value field, so its label is its only stop).
    ///
    /// `includingPhoneticName` is false while the Phonetic Name group is
    /// collapsed: its fields are not on screen then, so Tab must not go to
    /// them. `showsLabelField` says whether an entry's label (the label
    /// field, such as `.phoneLabel(0)`, and the entry's current label) is
    /// on screen as a text field; the option lists that decide it live in
    /// the app.
    public func tabOrder(
        includingPhoneticName: Bool,
        showsLabelField: (_ labelField: Field, _ label: String) -> Bool = { _, _ in false }
    ) -> [Field] {
        var order: [Field] = [
            .namePrefix, .givenName, .middleName, .familyName, .nameSuffix, .nickname,
            .organizationName, .departmentName, .jobTitle,
        ]
        // The rows with a label per entry, in on-screen order. Birthday, a
        // date picker, sits between Address and Dates and has no stop.
        let labeledRows: [(labels: [String], labelField: (Int) -> Field, valueFields: (Int) -> [Field])] = [
            (edited.phoneNumbers.map(\.label), Field.phoneLabel, { [.phone($0)] }),
            (edited.emailAddresses.map(\.label), Field.emailLabel, { [.email($0)] }),
            (visibleURLAddresses.map(\.label), Field.urlLabel, { [.url($0)] }),
            (edited.postalAddresses.map(\.label), Field.addressLabel, {
                [.street($0), .city($0), .state($0), .postalCode($0), .country($0)]
            }),
            // A date's value is a date picker, not a stop.
            (edited.dates.map(\.label), Field.dateLabel, { _ in [] }),
            (edited.contactRelations.map(\.label), Field.relationLabel, { [.relation($0)] }),
        ]
        for row in labeledRows {
            for (index, label) in row.labels.enumerated() {
                if showsLabelField(row.labelField(index), label) {
                    order.append(row.labelField(index))
                }
                order += row.valueFields(index)
            }
        }
        order += edited.socialProfiles.indices.map(Field.socialProfile)
        order += edited.instantMessageAddresses.indices.map(Field.instantMessage)
        if includingPhoneticName {
            order += [.phoneticGivenName, .phoneticMiddleName, .phoneticFamilyName]
        }
        order.append(.note)
        return order
    }

    /// The field Tab moves to from `field` in `order` (a `tabOrder`): the
    /// next one, or the previous one when `backward` (Shift-Tab). It wraps
    /// at both ends, so Tab never leaves the editor. A field that is not in
    /// the order (nil, or a field whose entry was just removed) moves to the
    /// first field, or to the last one when going backward. Nil only for an
    /// empty order.
    public static func tabStop(from field: Field?, backward: Bool, in order: [Field]) -> Field? {
        guard let field, let index = order.firstIndex(of: field) else {
            return backward ? order.last : order.first
        }
        let step = backward ? order.count - 1 : 1
        return order[(index + step) % order.count]
    }
}
