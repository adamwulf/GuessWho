import SwiftUI
import GuessWhoSync

struct ContactNotesRow: View {
    @Binding var model: ContactEditModel

    var body: some View {
        Section("Contact Notes") {
            TextField("Notes", text: $model.edited.note, axis: .vertical)
                .lineLimit(3...)
                .onChange(of: model.edited.note) { _, _ in model.isDirty = true }
                .centeredRowContent()
        }
    }
}
