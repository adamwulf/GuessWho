import SwiftUI
import Contacts
import GuessWhoSync

/// SwiftUI sheet editor for creating a brand-new Contact. The
/// existing-contact edit flow lives inline in `ContactDetailView`; this
/// sheet only runs the new-contact path (e.g. "Add Contact" from an
/// EventKit attendee), where there's no detail view to flip into yet.
///
/// Row implementations live under `Rows/`. Shared utilities (LabelPicker,
/// LabelOptions, LabeledTextSection, PlatformKeyboardType) live next to
/// this file.
///
/// `onDone` fires after a successful save. The caller is responsible for
/// reconcile + repository reload.
struct ContactEditView: View {
    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let onDone: () -> Void

    @State private var model: ContactEditModel
    @State private var saveError: ContactEditModel.SaveErrorCategory?
    @State private var showDiscardConfirm = false
    @State private var isSaving = false

    /// Brand-new-contact entry point: the `seed` ships pre-filled with
    /// whatever the caller already knows (e.g. attendee name + email).
    /// The model starts dirty so Save is enabled immediately and the user
    /// doesn't have to mutate a field to enable it.
    init(newContactSeed seed: Contact, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _model = State(initialValue: ContactEditModel(newContactSeed: seed))
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
        if !name.isEmpty { return name }
        if !model.edited.organizationName.isEmpty { return model.edited.organizationName }
        return "New Contact"
    }

    /// True when the user has any unsaved work that Cancel would lose.
    /// `isDirty` is true from the moment the new-contact editor opens (so
    /// Save enables on the seed values), so comparing `edited` to
    /// `original` instead correctly reports "no user changes yet" when
    /// the user opens the prefilled sheet and immediately Cancels.
    private var hasUnsavedChanges: Bool {
        model.edited != model.original
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if hasUnsavedChanges {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
            .disabled(isSaving)
        }
        // EditButton flips the Form into edit mode so .onMove drag handles
        // appear on the multi-value rows. Placed on .primaryAction (trailing)
        // beside Save so the toolbar reads Cancel | … | Edit · Save — matches
        // Apple's Mail/Reminders/Contacts convention rather than crowding
        // Cancel on the leading side.
        ToolbarItem(placement: .primaryAction) {
            EditButton()
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

    private func saveErrorMessage(for category: ContactEditModel.SaveErrorCategory) -> String {
        switch category {
        case .authorizationDenied:
            return "Contacts access was revoked. Open Settings to re-enable."
        case .invalidField(let detail):
            return "One of the fields was rejected by the system: \(detail)"
        case .recordDoesNotExist:
            return "This contact has been deleted on another device. Tap Cancel to refresh."
        case .unknown(let detail):
            return detail
        }
    }

}
