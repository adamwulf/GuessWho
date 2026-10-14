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
                    .focused(focus, equals: .phoneticGivenName)
                    .onSubmit { focus.wrappedValue = .phoneticMiddleName }
                    .editorTabStop(focus)
                    .onChange(of: model.edited.phoneticGivenName) { _, _ in model.isDirty = true }
                    .editorRow(.phoneticGivenName)
                TextField("Phonetic Middle", text: $model.edited.phoneticMiddleName)
                    .focused(focus, equals: .phoneticMiddleName)
                    .onSubmit { focus.wrappedValue = .phoneticFamilyName }
                    .editorTabStop(focus)
                    .onChange(of: model.edited.phoneticMiddleName) { _, _ in model.isDirty = true }
                    .editorRow(.phoneticMiddleName)
                TextField("Phonetic Last", text: $model.edited.phoneticFamilyName)
                    .focused(focus, equals: .phoneticFamilyName)
                    .editorTabStop(focus)
                    .onChange(of: model.edited.phoneticFamilyName) { _, _ in model.isDirty = true }
                    .editorRow(.phoneticFamilyName)
            }
            .centeredRowContent()
        }
    }
}
