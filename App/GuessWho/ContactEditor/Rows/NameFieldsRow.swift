import SwiftUI
import GuessWhoSync

struct NameFieldsRow: View {
    @Binding var model: ContactEditModel
    let focus: ContactEditorFocus

    var body: some View {
        Section {
            TextField("Prefix", text: $model.edited.namePrefix)
                .focused(focus, equals: .namePrefix)
                .onSubmit { focus.wrappedValue = .givenName }
                .editorTabStop(focus)
                .onChange(of: model.edited.namePrefix) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.namePrefix)
            TextField("First", text: $model.edited.givenName)
                .focused(focus, equals: .givenName)
                .onSubmit { focus.wrappedValue = .middleName }
                .editorTabStop(focus)
                .onChange(of: model.edited.givenName) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.givenName)
            TextField("Middle", text: $model.edited.middleName)
                .focused(focus, equals: .middleName)
                .onSubmit { focus.wrappedValue = .familyName }
                .editorTabStop(focus)
                .onChange(of: model.edited.middleName) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.middleName)
            TextField("Last", text: $model.edited.familyName)
                .focused(focus, equals: .familyName)
                .onSubmit { focus.wrappedValue = .nameSuffix }
                .editorTabStop(focus)
                .onChange(of: model.edited.familyName) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.familyName)
            TextField("Suffix", text: $model.edited.nameSuffix)
                .focused(focus, equals: .nameSuffix)
                .onSubmit { focus.wrappedValue = .nickname }
                .editorTabStop(focus)
                .onChange(of: model.edited.nameSuffix) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.nameSuffix)
            TextField("Nickname", text: $model.edited.nickname)
                .focused(focus, equals: .nickname)
                .editorTabStop(focus)
                .onChange(of: model.edited.nickname) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.nickname)
        }
    }
}
