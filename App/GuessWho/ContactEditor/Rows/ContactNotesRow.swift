import SwiftUI
import GuessWhoSync

struct ContactNotesRow: View {
    @Binding var model: ContactEditModel
    let focus: ContactEditorFocus

    var body: some View {
        TitledSection("Notes") {
            TextField("Notes", text: $model.edited.note, axis: .vertical)
                .lineLimit(3...)
                .focused(focus, equals: .field(.note))
                .editorTabStop(focus)
                .onChange(of: model.edited.note) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.note)
        }
    }
}
