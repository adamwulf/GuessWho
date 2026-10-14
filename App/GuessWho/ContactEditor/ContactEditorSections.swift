import SwiftUI
import GuessWhoSync

/// The contact editor's rows, in order. Shared by both editors: the
/// new-contact sheet (`ContactEditView`) and the inline edit of
/// `ContactDetailView`, which the "+" add flow also opens.
///
/// It owns the one focus state that every text field of every row binds
/// to, the host's trailing sections included, so Tab and Shift-Tab move
/// through the whole form in on-screen order (`editorTabStop`), not only
/// within one row. Tab from a control that is not a text field stays in
/// the form too (see `body`). The rows keep moving focus to the next field
/// of the same row on Return. The host puts `contactEditorScrolling()` on
/// its `List` / `Form` so Tab can bring a field below the visible part
/// into view.
struct ContactEditorSections<Trailing: View>: View {
    @Binding var model: ContactEditModel
    /// The stops of the text fields in `trailing`, in on-screen order. They
    /// come after the contact's own fields in the tab order, so Tab goes on
    /// from Notes through them and then wraps to the first field.
    let trailingStops: [ContactEditorStop]
    /// Sections the host shows after the contact's own fields: the inline
    /// edit's custom fields and dated notes, which save on their own,
    /// outside the model, and its Delete Contact button. Each of their text
    /// fields binds the editor focus with its stop from `trailingStops`
    /// (`editorTabStop(_:focus:)`).
    let trailing: (ContactEditorFocus) -> Trailing
    @FocusState private var focus: ContactEditorStop?
    /// Whether the Phonetic Name group is open. Held here, not in its row,
    /// because the tab order needs it: a closed group's fields are not stops.
    @State private var phoneticNameExpanded = false

    init(
        model: Binding<ContactEditModel>,
        trailingStops: [ContactEditorStop],
        @ViewBuilder trailing: @escaping (ContactEditorFocus) -> Trailing
    ) {
        _model = model
        self.trailingStops = trailingStops
        self.trailing = trailing
    }

    var body: some View {
        // `ContactEditModel.tabOrder` lists the text fields in this same
        // order; change both together. The trailing sections' stops follow.
        Group {
            NameFieldsRow(model: $model, focus: $focus)
            OrgFieldsRow(model: $model, focus: $focus)
            PhoneRow(model: $model, focus: $focus)
            EmailRow(model: $model, focus: $focus)
            URLRow(model: $model, focus: $focus)
            PostalAddressRow(model: $model, focus: $focus)
            BirthdayRow(model: $model)
            DateRow(model: $model, focus: $focus)
            RelationRow(model: $model, focus: $focus)
            SocialProfileRow(model: $model, focus: $focus)
            IMRow(model: $model, focus: $focus)
            PhoneticNameRow(model: $model, isExpanded: $phoneticNameExpanded, focus: $focus)
            ContactNotesRow(model: $model, focus: $focus)
            trailing($focus)
        }
        // Tab and Shift-Tab from a control that is not a text field (the
        // Organization toggle, a label menu, a date picker, an add or delete
        // button, the Phonetic Name disclosure). No text field takes the key
        // then, so the system's focus got it and could leave the form (to
        // the list column or its search field). A modifier on a `Group`
        // applies to each of its views, so every section of the form gets
        // this handler, for a key press from any control in it. A text
        // field's own `editorTabStop` takes the key first, so this runs only
        // for the other controls. With no stop focused, Tab goes to the
        // first stop and Shift-Tab to the last (`ContactEditModel.tabStop`):
        // this handler can't tell where in the form the control is. Whether
        // such a control has keyboard focus at all (so that the key comes
        // here) is up to the system; the hand check verifies it.
        .editorTabStop($focus)
        .environment(
            \.contactEditorTabOrder,
            model.tabOrder(includingPhoneticName: phoneticNameExpanded) { labelField, label in
                LabelPicker.showsTextField(for: label, options: Self.labelOptions(for: labelField))
            }.map(ContactEditorStop.field) + trailingStops
        )
    }

    /// The options the row of `labelField` gives its `LabelPicker`.
    private static func labelOptions(for labelField: ContactEditModel.Field) -> [String] {
        switch labelField {
        case .phoneLabel: LabelOptions.phone
        case .emailLabel: LabelOptions.email
        case .urlLabel: LabelOptions.url
        case .addressLabel: LabelOptions.address
        case .dateLabel: LabelOptions.date
        case .relationLabel: LabelOptions.relation
        default: []
        }
    }
}

extension ContactEditorSections where Trailing == EmptyView {
    /// The editor with nothing after the contact's fields (the new-contact
    /// sheet).
    init(model: Binding<ContactEditModel>) {
        self.init(model: model, trailingStops: []) { _ in EmptyView() }
    }
}
