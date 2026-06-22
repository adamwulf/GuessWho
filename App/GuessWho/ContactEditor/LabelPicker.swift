import SwiftUI
import Contacts

/// Cross-platform Menu-based label picker. Displays the localized form
/// of each option in the picker UI (via `CNLabeledValue.localizedString(forLabel:)`)
/// and stores the raw CN constant in the binding. A "Custom…" option
/// lets the user type their own label, stored verbatim. Matches
/// Contacts.app label-picking behavior.
///
/// The binding's target depends on the row type — most rows bind
/// LabeledValue.label, but Social and IM rows bind the underlying
/// struct's `.service` field (see LabelOptions for which lists target
/// which slot).
struct LabelPicker: View {
    @Binding var label: String
    let options: [String]
    @State private var showCustomSheet = false
    @State private var customDraft: String = ""

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(displayName(for: opt)) { label = opt }
            }
            Divider()
            Button("Custom…") {
                customDraft = label
                showCustomSheet = true
            }
        } label: {
            Text(displayName(for: label))
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .sheet(isPresented: $showCustomSheet) {
            CustomLabelSheet(draft: $customDraft) { result in
                if let result {
                    label = result
                }
                showCustomSheet = false
            }
        }
    }

    /// Resolve a raw CN constant to a user-facing string. Tries the
    /// label localizer first (`CNLabeledValue.localizedString(forLabel:)`),
    /// then the social-service and IM-service localizers — those handle
    /// constants like `CNSocialProfileServiceTwitter` /
    /// `CNInstantMessageServiceAIM` that the label localizer doesn't
    /// recognize. Falls back to the raw string if nothing matches.
    private func displayName(for raw: String) -> String {
        if raw.isEmpty { return "label" }
        let labelLocalized = CNLabeledValue<NSString>.localizedString(forLabel: raw)
        if labelLocalized != raw { return labelLocalized }
        let socialLocalized = CNSocialProfile.localizedString(forService: raw)
        if socialLocalized != raw { return socialLocalized }
        let imLocalized = CNInstantMessageAddress.localizedString(forService: raw)
        if imLocalized != raw { return imLocalized }
        return raw
    }
}

struct CustomLabelSheet: View {
    @Binding var draft: String
    let completion: (String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label", text: $draft)
            }
            .navigationTitle("Custom Label")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { completion(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { completion(draft) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 160)
        #endif
    }
}
