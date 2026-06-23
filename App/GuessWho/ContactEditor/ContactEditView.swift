import SwiftUI
import Contacts
import GuessWhoSync

/// SwiftUI editor for the CN fields of a Contact. Replaces the
/// CNContactViewController-backed UIKit bridge so the app builds on
/// native macOS (where ContactsUI is unavailable) and iOS with one code
/// path. See docs/swiftui-contact-editor-plan.md for the full design.
///
/// Row implementations live under `Rows/`. Shared utilities (LabelPicker,
/// LabelOptions, LabeledTextSection, PlatformKeyboardType) live next to
/// this file.
///
/// Callback semantics (preserved from the old UIKit bridge):
/// - `onDone`   — fires after a successful save. Caller handles
///                reconcile + repository reload.
/// - `onDelete` — fires after a successful delete (or CN reports the
///                contact already gone). Caller handles repository
///                reload + pop.
struct ContactEditView: View {
    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let contact: Contact
    let onDone: () -> Void
    let onDelete: () -> Void

    @State private var model: ContactEditModel
    @State private var saveError: ContactEditModel.SaveErrorCategory?
    @State private var deleteError: ContactEditModel.SaveErrorCategory?
    @State private var showDiscardConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isSaving = false

    init(contact: Contact, onDone: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.contact = contact
        self.onDone = onDone
        self.onDelete = onDelete
        _model = State(initialValue: ContactEditModel(original: contact))
    }

    var body: some View {
        NavigationStack {
            Form {
                NameFieldsRow(model: $model)
                OrgFieldsRow(model: $model)
                PhoneRow(model: $model)
                EmailRow(model: $model)
                URLRow(model: $model)
                PostalAddressRow(model: $model)
                BirthdayRow(model: $model)
                DateRow(model: $model)
                RelationRow(model: $model)
                SocialProfileRow(model: $model)
                IMRow(model: $model)
                PhoneticNameRow(model: $model)
                DeleteSection(showConfirm: $showDeleteConfirm)
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Discard changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete contact?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Contact", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Couldn't save",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                ),
                presenting: saveError
            ) { category in
                Button("OK", role: .cancel) { saveError = nil }
                if category == .authorizationDenied {
                    #if targetEnvironment(macCatalyst)
                    // Catalyst routes the x-apple.systempreferences:* URL
                    // through LaunchServices, landing the user in System
                    // Settings → Privacy & Security → Contacts so they can
                    // re-enable access. UIApplication.openSettingsURLString
                    // opens the host iOS Settings app on iOS but is a no-op
                    // on Catalyst, so the URL must differ per platform.
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            UIApplication.shared.open(url)
                        }
                    }
                    #else
                    Button("Open Settings") {
                        // iOS deep-link to the app's Settings page so the
                        // user can re-enable Contacts access.
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    #endif
                }
            } message: { category in
                Text(saveErrorMessage(for: category))
            }
            .alert(
                "Couldn't delete",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                ),
                presenting: deleteError
            ) { category in
                Button("OK", role: .cancel) { deleteError = nil }
                if category == .authorizationDenied {
                    #if targetEnvironment(macCatalyst)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            UIApplication.shared.open(url)
                        }
                    }
                    #else
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    #endif
                }
            } message: { category in
                Text(deleteErrorMessage(for: category))
            }
        }
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 600, idealHeight: 720)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var navigationTitle: String {
        let name = [model.edited.givenName, model.edited.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty
            ? (model.edited.organizationName.isEmpty ? "Edit Contact" : model.edited.organizationName)
            : name
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if model.isDirty {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                Task { await performSave() }
            }
            .disabled(!model.isDirty || isSaving)
        }
    }

    private func performSave() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.saveContact(model.edited)
            onDone()
            dismiss()
        } catch {
            saveError = ContactEditModel.saveErrorCategory(error)
        }
    }

    private func performDelete() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.deleteContact(localID: contact.localID)
            onDelete()
            dismiss()
        } catch {
            let category = ContactEditModel.saveErrorCategory(error)
            // recordDoesNotExist means the contact is already gone —
            // exactly what the user asked for. Treat as success.
            if category == .recordDoesNotExist {
                onDelete()
                dismiss()
            } else {
                deleteError = category
            }
        }
    }

    private func saveErrorMessage(for category: ContactEditModel.SaveErrorCategory) -> String {
        switch category {
        case .authorizationDenied:
            return "Contacts access was revoked. Open Settings to re-enable."
        case .invalidField(let detail):
            return "One of the fields was rejected by the system: \(detail)"
        case .recordDoesNotExist:
            return "This contact has been deleted on another device. Close the editor to refresh."
        case .unknown(let detail):
            return detail
        }
    }

    private func deleteErrorMessage(for category: ContactEditModel.SaveErrorCategory) -> String {
        switch category {
        case .authorizationDenied:
            return "Contacts access was revoked. Open Settings to re-enable."
        case .invalidField(let detail):
            return "The system rejected the delete: \(detail)"
        case .recordDoesNotExist:
            // Shouldn't reach here — performDelete treats this as success.
            return "Contact already deleted."
        case .unknown(let detail):
            return detail
        }
    }
}

// MARK: - Delete section (lives with the editor since it's editor-local)

private struct DeleteSection: View {
    @Binding var showConfirm: Bool
    var body: some View {
        Section {
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Contact")
                    Spacer()
                }
            }
        }
    }
}
