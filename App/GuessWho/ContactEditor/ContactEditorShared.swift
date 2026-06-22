import SwiftUI
import GuessWhoSync

// MARK: - LabeledTextSection (shared by phone/email/url rows)

/// Section template used by phone, email, and URL rows. Renders each
/// entry as a label picker + a text field, plus an always-visible
/// "Add" button at the bottom (per the plan's section-visibility rule).
struct LabeledTextSection: View {
    let title: String
    let placeholder: String
    @Binding var items: [LabeledValue]
    let labelOptions: [String]
    let keyboardType: PlatformKeyboardType

    var body: some View {
        Section(title) {
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
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            Button {
                items.append(LabeledValue(label: labelOptions.first ?? "", value: ""))
            } label: {
                Label("Add \(title)", systemImage: "plus.circle.fill")
            }
        }
    }
}

// MARK: - Cross-platform keyboard helper

enum PlatformKeyboardType {
    case `default`, phonePad, emailAddress, URL
}

extension View {
    @ViewBuilder
    func applyKeyboard(_ type: PlatformKeyboardType) -> some View {
        #if os(macOS)
        self
        #else
        switch type {
        case .default: self
        case .phonePad: self.keyboardType(.phonePad)
        case .emailAddress: self.keyboardType(.emailAddress)
        case .URL: self.keyboardType(.URL)
        }
        #endif
    }
}
