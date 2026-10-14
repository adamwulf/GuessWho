import SwiftUI
import GuessWhoSync

/// Section template used by phone, email, and URL rows. Renders each
/// entry as a label picker + a text field, plus an always-visible
/// "Add" button at the bottom.
struct LabeledTextSection: View {
    let title: String
    let placeholder: String
    @Binding var items: [LabeledValue]
    let labelOptions: [String]
    let keyboardType: PlatformKeyboardType
    let focus: ContactEditorFocus
    /// The editor field for the entry at an index (e.g. `ContactEditModel.Field.phone`).
    let field: (Int) -> ContactEditModel.Field
    /// The editor field for the entry's label text field (e.g.
    /// `ContactEditModel.Field.phoneLabel`), shown for an Other or typed label.
    let labelField: (Int) -> ContactEditModel.Field
    /// Applied to every edit before it is stored, so a row can rewrite
    /// pasted text (e.g. email strips a display name). Must return its
    /// input unchanged for text it doesn't rewrite.
    var normalizeValue: (String) -> String = { $0 }

    var body: some View {
        TitledSection(title) {
            ForEach(items.indices, id: \.self) { idx in
                HStack {
                    LabelPicker(
                        label: Binding(
                            get: { items[idx].label },
                            set: { items[idx] = LabeledValue(label: $0, value: items[idx].value) }
                        ),
                        options: labelOptions,
                        focus: focus,
                        field: labelField(idx)
                    )
                    TextField(placeholder, text: Binding(
                        get: { items[idx].value },
                        set: { items[idx] = LabeledValue(label: items[idx].label, value: normalizeValue($0)) }
                    ))
                    .applyKeyboard(keyboardType)
                    #if !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused(focus, equals: field(idx))
                    .editorTabStop(focus)
                }
                .centeredRowContent()
                .editorRow(field(idx))
            }
            .onDelete { items.remove(atOffsets: $0) }
            .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            Button {
                items.append(LabeledValue(label: labelOptions.first ?? "", value: ""))
            } label: {
                Label("Add \(title)", systemImage: "plus.circle.fill")
            }
            .centeredRowContent()
        }
    }
}
