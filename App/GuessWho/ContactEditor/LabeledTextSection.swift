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

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { idx in
                HStack {
                    LabelPicker(
                        label: Binding(
                            get: { items[idx].label },
                            set: { items[idx] = LabeledValue(label: $0, value: items[idx].value) }
                        ),
                        options: labelOptions
                    )
                    TextField(placeholder, text: Binding(
                        get: { items[idx].value },
                        set: { items[idx] = LabeledValue(label: items[idx].label, value: $0) }
                    ))
                    .applyKeyboard(keyboardType)
                    #if !targetEnvironment(macCatalyst)
                    .textInputAutocapitalization(.never)
                    #endif
                }
                .centeredRowContent()
            }
            .onDelete { items.remove(atOffsets: $0) }
            .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            Button {
                items.append(LabeledValue(label: labelOptions.first ?? "", value: ""))
            } label: {
                Label("Add \(title)", systemImage: "plus.circle.fill")
            }
            .centeredRowContent()
        } header: {
            Text(title).centeredSectionHeader()
        }
    }
}
