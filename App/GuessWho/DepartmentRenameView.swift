import SwiftUI

/// A one-field edit form for renaming a department, presented as a sheet from
/// `DepartmentMembersListViewController`. Defaults to the current department
/// name, disallows an empty name (Save is disabled until the trimmed field is
/// non-empty), and offers Cancel / Save just like the other editor sheets (see
/// `EventLinkSheet`). Saving hands the trimmed new name back to the caller,
/// which rewrites it across the organization's matching contacts.
struct DepartmentRenameView: View {
    let originalName: String
    /// Called with the trimmed, non-empty new name when the user taps Save.
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var fieldFocused: Bool

    init(
        originalName: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalName = originalName
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Department Name") {
                    TextField("Department", text: $name)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { if canSave { onSave(trimmedName) } }
                }
            }
            .navigationTitle("Rename Department")
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(trimmedName) }
                        .disabled(!canSave)
                }
            }
            .onAppear { fieldFocused = true }
        }
    }
}
