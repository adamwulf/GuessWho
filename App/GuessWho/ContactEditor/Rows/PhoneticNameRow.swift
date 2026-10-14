import SwiftUI
import GuessWhoSync

struct PhoneticNameRow: View {
    @Binding var model: ContactEditModel
    /// Owned by `ContactEditorSections`: the tab order skips these fields
    /// while the group is closed.
    @Binding var isExpanded: Bool
    let focus: ContactEditorFocus

    var body: some View {
        Section {
            DisclosureGroup("Phonetic Name", isExpanded: $isExpanded) {
                TextField("Phonetic First", text: $model.edited.phoneticGivenName)
                    .focused(focus, equals: .field(.phoneticGivenName))
                    .onSubmit { focus.wrappedValue = .field(.phoneticMiddleName) }
                    .editorTabStop(focus)
                    .onChange(of: model.edited.phoneticGivenName) { _, _ in model.isDirty = true }
                    .editorRow(.phoneticGivenName)
                TextField("Phonetic Middle", text: $model.edited.phoneticMiddleName)
                    .focused(focus, equals: .field(.phoneticMiddleName))
                    .onSubmit { focus.wrappedValue = .field(.phoneticFamilyName) }
                    .editorTabStop(focus)
                    .onChange(of: model.edited.phoneticMiddleName) { _, _ in model.isDirty = true }
                    .editorRow(.phoneticMiddleName)
                TextField("Phonetic Last", text: $model.edited.phoneticFamilyName)
                    .focused(focus, equals: .field(.phoneticFamilyName))
                    .editorTabStop(focus)
                    .onChange(of: model.edited.phoneticFamilyName) { _, _ in model.isDirty = true }
                    .editorRow(.phoneticFamilyName)
            }
            .centeredRowContent()
        }
    }
}
