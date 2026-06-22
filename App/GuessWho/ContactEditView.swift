import SwiftUI
import Contacts
import GuessWhoSync

/// SwiftUI editor for the CN fields of a Contact. Replaces the
/// CNContactViewController-backed UIKit bridge so the app builds on
/// native macOS (where ContactsUI is unavailable) and iOS with one code
/// path. See docs/swiftui-contact-editor-plan.md for the full design.
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
                NameSection(model: $model)
                OrgSection(model: $model)
                PhoneSection(model: $model)
                EmailSection(model: $model)
                URLSection(model: $model)
                PostalSection(model: $model)
                BirthdaySection(model: $model)
                DatesSection(model: $model)
                RelationsSection(model: $model)
                SocialSection(model: $model)
                IMSection(model: $model)
                PhoneticSection(model: $model)
                DeleteSection(showConfirm: $showDeleteConfirm)
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            #if !os(macOS)
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
                #if !os(macOS)
                if category == .authorizationDenied {
                    Button("Open Settings") {
                        // iOS-only deep-link to the app's Settings page so
                        // the user can re-enable Contacts access. Native
                        // macOS has no equivalent URL; alert is text-only.
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                #endif
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
            ) { _ in
                Button("OK", role: .cancel) { deleteError = nil }
            } message: { category in
                Text(deleteErrorMessage(for: category))
            }
        }
        #if os(macOS)
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

// MARK: - Name & Phonetic

private struct NameSection: View {
    @Binding var model: ContactEditModel
    @FocusState private var focus: NameField?

    private enum NameField: Hashable {
        case prefix, given, middle, family, suffix, nickname
    }

    var body: some View {
        Section {
            TextField("Prefix", text: $model.edited.namePrefix)
                .focused($focus, equals: .prefix)
                .onSubmit { focus = .given }
                .onChange(of: model.edited.namePrefix) { _, _ in model.isDirty = true }
            TextField("First", text: $model.edited.givenName)
                .focused($focus, equals: .given)
                .onSubmit { focus = .middle }
                .onChange(of: model.edited.givenName) { _, _ in model.isDirty = true }
            TextField("Middle", text: $model.edited.middleName)
                .focused($focus, equals: .middle)
                .onSubmit { focus = .family }
                .onChange(of: model.edited.middleName) { _, _ in model.isDirty = true }
            TextField("Last", text: $model.edited.familyName)
                .focused($focus, equals: .family)
                .onSubmit { focus = .suffix }
                .onChange(of: model.edited.familyName) { _, _ in model.isDirty = true }
            TextField("Suffix", text: $model.edited.nameSuffix)
                .focused($focus, equals: .suffix)
                .onSubmit { focus = .nickname }
                .onChange(of: model.edited.nameSuffix) { _, _ in model.isDirty = true }
            TextField("Nickname", text: $model.edited.nickname)
                .focused($focus, equals: .nickname)
                .onChange(of: model.edited.nickname) { _, _ in model.isDirty = true }
        }
    }
}

private struct PhoneticSection: View {
    @Binding var model: ContactEditModel
    @State private var expanded = false
    @FocusState private var focus: PhoneticField?

    private enum PhoneticField: Hashable {
        case given, middle, family
    }

    var body: some View {
        Section {
            DisclosureGroup("Phonetic Name", isExpanded: $expanded) {
                TextField("Phonetic First", text: $model.edited.phoneticGivenName)
                    .focused($focus, equals: .given)
                    .onSubmit { focus = .middle }
                    .onChange(of: model.edited.phoneticGivenName) { _, _ in model.isDirty = true }
                TextField("Phonetic Middle", text: $model.edited.phoneticMiddleName)
                    .focused($focus, equals: .middle)
                    .onSubmit { focus = .family }
                    .onChange(of: model.edited.phoneticMiddleName) { _, _ in model.isDirty = true }
                TextField("Phonetic Last", text: $model.edited.phoneticFamilyName)
                    .focused($focus, equals: .family)
                    .onChange(of: model.edited.phoneticFamilyName) { _, _ in model.isDirty = true }
            }
        }
    }
}

// MARK: - Organization

private struct OrgSection: View {
    @Binding var model: ContactEditModel
    @FocusState private var focus: OrgField?

    private enum OrgField: Hashable {
        case organization, department, jobTitle
    }

    var body: some View {
        Section("Organization") {
            TextField("Company", text: $model.edited.organizationName)
                .focused($focus, equals: .organization)
                .onSubmit { focus = .department }
                .onChange(of: model.edited.organizationName) { _, _ in model.isDirty = true }
            TextField("Department", text: $model.edited.departmentName)
                .focused($focus, equals: .department)
                .onSubmit { focus = .jobTitle }
                .onChange(of: model.edited.departmentName) { _, _ in model.isDirty = true }
            TextField("Job Title", text: $model.edited.jobTitle)
                .focused($focus, equals: .jobTitle)
                .onChange(of: model.edited.jobTitle) { _, _ in model.isDirty = true }
        }
    }
}

// MARK: - Phone / Email / URL (labeled text rows)

private struct PhoneSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        LabeledTextSection(
            title: "Phone",
            placeholder: "Phone",
            items: Binding(get: { model.edited.phoneNumbers }, set: {
                model.edited.phoneNumbers = $0
                model.isDirty = true
            }),
            labelOptions: LabelOptions.phone,
            keyboardType: .phonePad
        )
    }
}

private struct EmailSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        LabeledTextSection(
            title: "Email",
            placeholder: "Email",
            items: Binding(get: { model.edited.emailAddresses }, set: {
                model.edited.emailAddresses = $0
                model.isDirty = true
            }),
            labelOptions: LabelOptions.email,
            keyboardType: .emailAddress
        )
    }
}

private struct URLSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        LabeledTextSection(
            title: "URL",
            placeholder: "URL",
            items: Binding(
                get: { model.visibleURLAddresses },
                set: {
                    model.visibleURLAddresses = $0
                    model.isDirty = true
                }
            ),
            labelOptions: LabelOptions.url,
            keyboardType: .URL
        )
    }
}

private struct LabeledTextSection: View {
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

// MARK: - Postal address

private struct PostalSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Address") {
            ForEach(model.edited.postalAddresses.indices, id: \.self) { idx in
                PostalAddressEditor(
                    entry: Binding(
                        get: { model.edited.postalAddresses[idx] },
                        set: {
                            model.edited.postalAddresses[idx] = $0
                            model.isDirty = true
                        }
                    )
                )
            }
            .onDelete { offsets in
                model.edited.postalAddresses.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                model.edited.postalAddresses.append(
                    LabeledPostalAddress(
                        label: LabelOptions.address.first ?? "",
                        value: PostalAddress()
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add Address", systemImage: "plus.circle.fill")
            }
        }
    }
}

private struct PostalAddressEditor: View {
    @Binding var entry: LabeledPostalAddress
    @FocusState private var focus: PostalField?

    private enum PostalField: Hashable {
        case street, city, state, postal, country
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelPicker(
                label: Binding(
                    get: { entry.label },
                    set: { entry = LabeledPostalAddress(label: $0, value: entry.value) }
                ),
                options: LabelOptions.address
            )
            TextField("Street", text: binding(\.street))
                .focused($focus, equals: .street)
                .onSubmit { focus = .city }
            TextField("City", text: binding(\.city))
                .focused($focus, equals: .city)
                .onSubmit { focus = .state }
            TextField("State", text: binding(\.state))
                .focused($focus, equals: .state)
                .onSubmit { focus = .postal }
            TextField("Postal Code", text: binding(\.postalCode))
                .focused($focus, equals: .postal)
                .onSubmit { focus = .country }
            TextField("Country", text: binding(\.country))
                .focused($focus, equals: .country)
        }
    }

    /// Bind a writable keypath on PostalAddress while leaving the
    /// non-edited sub-fields (`subLocality`, `subAdministrativeArea`,
    /// `isoCountryCode`) untouched — carry-through preservation per
    /// docs/swiftui-contact-editor-plan.md §"Data preservation".
    private func binding(_ keyPath: WritableKeyPath<PostalAddress, String>) -> Binding<String> {
        Binding(
            get: { entry.value[keyPath: keyPath] },
            set: { newValue in
                var pa = entry.value
                pa[keyPath: keyPath] = newValue
                entry = LabeledPostalAddress(label: entry.label, value: pa)
            }
        )
    }
}

// MARK: - Birthday & Dates

private struct BirthdaySection: View {
    @Binding var model: ContactEditModel
    @State private var expanded: Bool = false

    var body: some View {
        Section("Birthday") {
            if model.edited.birthday != nil {
                DatePicker(
                    "Birthday",
                    selection: Binding(
                        get: { model.birthdayAsDate() ?? Date() },
                        set: { model.setBirthday(from: $0) }
                    ),
                    displayedComponents: model.birthdayHasYear ? [.date] : [.date]
                )
                .labelsHidden()
                Toggle("Include year", isOn: Binding(
                    get: { model.birthdayHasYear },
                    set: { newValue in
                        let prev = model.birthdayHasYear
                        model.birthdayHasYear = newValue
                        // When toggling, re-write the birthday so the
                        // stored DateComponents reflects the new shape.
                        if prev != newValue, let d = model.birthdayAsDate() {
                            model.setBirthday(from: d)
                        }
                    }
                ))
                Button(role: .destructive) {
                    model.clearBirthday()
                } label: {
                    Label("Remove Birthday", systemImage: "minus.circle")
                }
            } else {
                Button {
                    var dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                    model.edited.birthday = dc
                    model.birthdayHasYear = (dc.year != nil)
                    model.isDirty = true
                    _ = dc // silence unused warning paths
                } label: {
                    Label("Add Birthday", systemImage: "plus.circle.fill")
                }
            }
        }
    }
}

private struct DatesSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Dates") {
            ForEach(model.edited.dates.indices, id: \.self) { idx in
                HStack {
                    LabelPicker(
                        label: Binding(
                            get: { model.edited.dates[idx].label },
                            set: {
                                model.edited.dates[idx] = LabeledDate(
                                    label: $0,
                                    value: model.edited.dates[idx].value
                                )
                                model.isDirty = true
                            }
                        ),
                        options: LabelOptions.date
                    )
                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: {
                                Calendar.current.date(from: model.edited.dates[idx].value)
                                    ?? Date()
                            },
                            set: { newDate in
                                let dc = Calendar.current.dateComponents(
                                    [.year, .month, .day],
                                    from: newDate
                                )
                                model.edited.dates[idx] = LabeledDate(
                                    label: model.edited.dates[idx].label,
                                    value: dc
                                )
                                model.isDirty = true
                            }
                        ),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }
            }
            .onDelete { offsets in
                model.edited.dates.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                let dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                model.edited.dates.append(
                    LabeledDate(label: LabelOptions.date.first ?? "", value: dc)
                )
                model.isDirty = true
            } label: {
                Label("Add Date", systemImage: "plus.circle.fill")
            }
        }
    }
}

// MARK: - Relations / Social / IM

private struct RelationsSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Related") {
            ForEach(model.edited.contactRelations.indices, id: \.self) { idx in
                HStack {
                    LabelPicker(
                        label: Binding(
                            get: { model.edited.contactRelations[idx].label },
                            set: {
                                model.edited.contactRelations[idx] = LabeledContactRelation(
                                    label: $0,
                                    value: model.edited.contactRelations[idx].value
                                )
                                model.isDirty = true
                            }
                        ),
                        options: LabelOptions.relation
                    )
                    TextField("Name", text: Binding(
                        get: { model.edited.contactRelations[idx].value.name },
                        set: {
                            model.edited.contactRelations[idx] = LabeledContactRelation(
                                label: model.edited.contactRelations[idx].label,
                                value: ContactRelation(name: $0)
                            )
                            model.isDirty = true
                        }
                    ))
                }
            }
            .onDelete { offsets in
                model.edited.contactRelations.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                model.edited.contactRelations.append(
                    LabeledContactRelation(
                        label: LabelOptions.relation.first ?? "",
                        value: ContactRelation(name: "")
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add Related", systemImage: "plus.circle.fill")
            }
        }
    }
}

private struct SocialSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Social Profile") {
            ForEach(model.edited.socialProfiles.indices, id: \.self) { idx in
                VStack(alignment: .leading) {
                    LabelPicker(
                        label: Binding(
                            get: { model.edited.socialProfiles[idx].label },
                            set: {
                                let entry = model.edited.socialProfiles[idx]
                                model.edited.socialProfiles[idx] = LabeledSocialProfile(
                                    label: $0,
                                    value: entry.value
                                )
                                model.isDirty = true
                            }
                        ),
                        options: LabelOptions.social
                    )
                    TextField("Service", text: socialBinding(\.service, idx: idx))
                    TextField("Username", text: socialBinding(\.username, idx: idx))
                    TextField("URL", text: socialBinding(\.urlString, idx: idx))
                }
            }
            .onDelete { offsets in
                model.edited.socialProfiles.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                model.edited.socialProfiles.append(
                    LabeledSocialProfile(
                        label: LabelOptions.social.first ?? "",
                        value: SocialProfile()
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add Social Profile", systemImage: "plus.circle.fill")
            }
        }
    }

    private func socialBinding(
        _ keyPath: WritableKeyPath<SocialProfile, String>,
        idx: Int
    ) -> Binding<String> {
        Binding(
            get: { model.edited.socialProfiles[idx].value[keyPath: keyPath] },
            set: { newValue in
                let entry = model.edited.socialProfiles[idx]
                var sp = entry.value
                sp[keyPath: keyPath] = newValue
                model.edited.socialProfiles[idx] = LabeledSocialProfile(
                    label: entry.label,
                    value: sp
                )
                model.isDirty = true
            }
        )
    }
}

private struct IMSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Instant Message") {
            ForEach(model.edited.instantMessageAddresses.indices, id: \.self) { idx in
                VStack(alignment: .leading) {
                    LabelPicker(
                        label: Binding(
                            get: { model.edited.instantMessageAddresses[idx].label },
                            set: {
                                let entry = model.edited.instantMessageAddresses[idx]
                                model.edited.instantMessageAddresses[idx] = LabeledInstantMessageAddress(
                                    label: $0,
                                    value: entry.value
                                )
                                model.isDirty = true
                            }
                        ),
                        options: LabelOptions.instantMessage
                    )
                    TextField("Service", text: imBinding(\.service, idx: idx))
                    TextField("Username", text: imBinding(\.username, idx: idx))
                }
            }
            .onDelete { offsets in
                model.edited.instantMessageAddresses.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                model.edited.instantMessageAddresses.append(
                    LabeledInstantMessageAddress(
                        label: LabelOptions.instantMessage.first ?? "",
                        value: InstantMessageAddress()
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add IM", systemImage: "plus.circle.fill")
            }
        }
    }

    private func imBinding(
        _ keyPath: WritableKeyPath<InstantMessageAddress, String>,
        idx: Int
    ) -> Binding<String> {
        Binding(
            get: { model.edited.instantMessageAddresses[idx].value[keyPath: keyPath] },
            set: { newValue in
                let entry = model.edited.instantMessageAddresses[idx]
                var im = entry.value
                im[keyPath: keyPath] = newValue
                model.edited.instantMessageAddresses[idx] = LabeledInstantMessageAddress(
                    label: entry.label,
                    value: im
                )
                model.isDirty = true
            }
        )
    }
}

// MARK: - Delete

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

// MARK: - LabelPicker

/// Cross-platform Menu-based label picker. Displays the localized form
/// of each option in the picker UI (via `CNLabeledValue.localizedString(forLabel:)`)
/// and stores the raw CN constant in the model. A "Custom…" option lets
/// the user type their own label, stored verbatim. Matches Contacts.app
/// label-picking behavior.
private struct LabelPicker: View {
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

    private func displayName(for raw: String) -> String {
        if raw.isEmpty { return "label" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }
}

private struct CustomLabelSheet: View {
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

// MARK: - LabelOptions — standard CN label constants per field type

private enum LabelOptions {
    static let phone: [String] = [
        CNLabelPhoneNumberMobile,
        CNLabelPhoneNumberiPhone,
        CNLabelHome,
        CNLabelWork,
        CNLabelPhoneNumberMain,
        CNLabelPhoneNumberHomeFax,
        CNLabelPhoneNumberWorkFax,
        CNLabelPhoneNumberPager,
        CNLabelOther
    ]

    static let email: [String] = [
        CNLabelHome,
        CNLabelWork,
        CNLabelSchool,
        CNLabelOther
    ]

    static let url: [String] = [
        CNLabelURLAddressHomePage,
        CNLabelHome,
        CNLabelWork,
        CNLabelOther
    ]

    static let address: [String] = [
        CNLabelHome,
        CNLabelWork,
        CNLabelSchool,
        CNLabelOther
    ]

    static let date: [String] = [
        CNLabelDateAnniversary,
        CNLabelOther
    ]

    static let relation: [String] = [
        CNLabelContactRelationFather,
        CNLabelContactRelationMother,
        CNLabelContactRelationParent,
        CNLabelContactRelationBrother,
        CNLabelContactRelationSister,
        CNLabelContactRelationChild,
        CNLabelContactRelationSon,
        CNLabelContactRelationDaughter,
        CNLabelContactRelationFriend,
        CNLabelContactRelationSpouse,
        CNLabelContactRelationPartner,
        CNLabelContactRelationManager,
        CNLabelContactRelationAssistant,
        CNLabelContactRelationColleague,
        CNLabelOther
    ]

    static let social: [String] = [
        CNSocialProfileServiceTwitter,
        CNSocialProfileServiceFacebook,
        CNSocialProfileServiceLinkedIn,
        CNSocialProfileServiceGameCenter,
        CNSocialProfileServiceMySpace,
        CNSocialProfileServiceFlickr,
        CNSocialProfileServiceSinaWeibo,
        CNSocialProfileServiceTencentWeibo,
        CNSocialProfileServiceYelp
    ]

    static let instantMessage: [String] = [
        CNInstantMessageServiceAIM,
        CNInstantMessageServiceFacebook,
        CNInstantMessageServiceGaduGadu,
        CNInstantMessageServiceGoogleTalk,
        CNInstantMessageServiceICQ,
        CNInstantMessageServiceJabber,
        CNInstantMessageServiceMSN,
        CNInstantMessageServiceQQ,
        CNInstantMessageServiceSkype,
        CNInstantMessageServiceYahoo
    ]
}

// MARK: - Cross-platform keyboard helper

private enum PlatformKeyboardType {
    case `default`, phonePad, emailAddress, URL
}

private extension View {
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
