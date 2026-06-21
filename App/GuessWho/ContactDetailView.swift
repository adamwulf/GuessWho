import SwiftUI
import Contacts
import GuessWhoSync

struct ContactDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let localID: String

    @State private var contact: Contact?
    @State private var sidecar: SidecarEnvelope?
    @State private var notesStore: NotesStore?
    @State private var reconcileOutcome: IdentityReconcileReport.ContactOutcome?
    @State private var reconcileError: String?
    @State private var didAutoReconcile = false

    // Focus identity covers both the bottom new-note editor and any row
    // currently being edited. Hoisted here so a single nav-bar checkmark
    // can commit whichever edit is active and dismiss the keyboard.
    fileprivate enum NoteFocus: Hashable {
        case newNote
        case row(UUID)
    }
    @FocusState private var noteFocus: NoteFocus?
    @State private var newNoteText: String = ""
    @State private var editingID: UUID?
    @State private var draftBody: String = ""
    // Body captured at edit-start, used by §12.5's no-op-tap rule: commit
    // is a no-op only when the draft is unchanged from this snapshot —
    // never the current on-disk value. Matters when a reconcile lands
    // mid-edit and rewrites the on-disk body.
    @State private var editStartSnapshot: String = ""

    private var isEditingAnything: Bool {
        noteFocus != nil
    }

    var body: some View {
        Form {
            if let contact {
                nameSection(contact)
                workSection(contact)
                phoneSection(contact)
                emailSection(contact)
                addressSection(contact)
                urlSection(contact)
                datesSection(contact)
                socialSection(contact)
                instantMessageSection(contact)
                relationsSection(contact)

                if let notesStore {
                    NotesSection(
                        store: notesStore,
                        newNoteText: $newNoteText,
                        editingID: $editingID,
                        draftBody: $draftBody,
                        noteFocus: $noteFocus,
                        beginEdit: beginEdit(_:),
                        deleteNote: deleteNote(_:)
                    )
                }

                #if DEBUG
                debugSection(contact)
                #endif
            } else {
                ProgressView()
            }
        }
        .navigationTitle(contact?.displayName ?? "Contact")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    commitActiveEdit()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Back")
            }
            if isEditingAnything {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commitActiveEdit()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .accessibilityLabel("Done")
                }
            }
        }
        .task {
            await loadContact()
            if !didAutoReconcile {
                didAutoReconcile = true
                await performReconcile()
            }
        }
        .onDisappear {
            // Backstop for the edge-swipe-back gesture: the system pop
            // bypasses our custom back button, so commit here too. A no-op
            // if commitActiveEdit() already ran from a button tap.
            commitActiveEdit()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func nameSection(_ contact: Contact) -> some View {
        let rows: [(String, String)] = [
            ("Prefix", contact.namePrefix),
            ("Given", contact.givenName),
            ("Middle", contact.middleName),
            ("Family", contact.familyName),
            ("Previous Family", contact.previousFamilyName),
            ("Suffix", contact.nameSuffix),
            ("Nickname", contact.nickname),
            ("Phonetic Given", contact.phoneticGivenName),
            ("Phonetic Middle", contact.phoneticMiddleName),
            ("Phonetic Family", contact.phoneticFamilyName),
        ].filter { !$0.1.isEmpty }

        if !rows.isEmpty {
            Section("Name") {
                LabeledContent("Display", value: contact.displayName)
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                }
            }
        }
    }

    @ViewBuilder
    private func workSection(_ contact: Contact) -> some View {
        let rows: [(String, String)] = [
            ("Job Title", contact.jobTitle),
            ("Department", contact.departmentName),
            ("Organization", contact.organizationName),
            ("Phonetic Organization", contact.phoneticOrganizationName),
        ].filter { !$0.1.isEmpty }

        if !rows.isEmpty {
            Section("Work") {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0, value: row.1)
                }
            }
        }
    }

    @ViewBuilder
    private func phoneSection(_ contact: Contact) -> some View {
        if !contact.phoneNumbers.isEmpty {
            Section("Phone") {
                ForEach(Array(contact.phoneNumbers.enumerated()), id: \.offset) { _, item in
                    LabeledContent(localizedLabel(item.label), value: item.value)
                }
            }
        }
    }

    @ViewBuilder
    private func emailSection(_ contact: Contact) -> some View {
        if !contact.emailAddresses.isEmpty {
            Section("Email") {
                ForEach(Array(contact.emailAddresses.enumerated()), id: \.offset) { _, item in
                    LabeledContent(localizedLabel(item.label), value: item.value)
                }
            }
        }
    }

    @ViewBuilder
    private func addressSection(_ contact: Contact) -> some View {
        if !contact.postalAddresses.isEmpty {
            Section("Address") {
                ForEach(Array(contact.postalAddresses.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedLabel(item.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatPostalAddress(item.value))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func urlSection(_ contact: Contact) -> some View {
        // GuessWho's internal guesswho:// URLs are an implementation
        // detail; the user-facing URL list omits them and they appear
        // in the DEBUG section instead.
        let userURLs = contact.urlAddresses.filter {
            SidecarKey.parseGuessWhoContactURL($0.value) == nil
        }
        if !userURLs.isEmpty {
            Section("URL") {
                ForEach(Array(userURLs.enumerated()), id: \.offset) { _, item in
                    LabeledContent(localizedLabel(item.label), value: item.value)
                }
            }
        }
    }

    @ViewBuilder
    private func datesSection(_ contact: Contact) -> some View {
        let hasAnyDate = contact.birthday != nil
            || contact.nonGregorianBirthday != nil
            || !contact.dates.isEmpty

        if hasAnyDate {
            Section("Dates") {
                if let bday = contact.birthday {
                    LabeledContent("Birthday", value: formatDateComponents(bday))
                }
                if let nonGreg = contact.nonGregorianBirthday {
                    LabeledContent("Non-Gregorian Birthday", value: formatDateComponents(nonGreg))
                }
                ForEach(Array(contact.dates.enumerated()), id: \.offset) { _, item in
                    LabeledContent(localizedLabel(item.label), value: formatDateComponents(item.value))
                }
            }
        }
    }

    @ViewBuilder
    private func socialSection(_ contact: Contact) -> some View {
        if !contact.socialProfiles.isEmpty {
            Section("Social Profiles") {
                ForEach(Array(contact.socialProfiles.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(socialProfileLabel(item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(socialProfileValue(item.value))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func instantMessageSection(_ contact: Contact) -> some View {
        if !contact.instantMessageAddresses.isEmpty {
            Section("Instant Message") {
                ForEach(Array(contact.instantMessageAddresses.enumerated()), id: \.offset) { _, item in
                    LabeledContent(instantMessageLabel(item), value: item.value.username)
                }
            }
        }
    }

    @ViewBuilder
    private func relationsSection(_ contact: Contact) -> some View {
        if !contact.contactRelations.isEmpty {
            Section("Related") {
                ForEach(Array(contact.contactRelations.enumerated()), id: \.offset) { _, item in
                    LabeledContent(localizedLabel(item.label), value: item.value.name)
                }
            }
        }
    }

    #if DEBUG
    @ViewBuilder
    private func debugSection(_ contact: Contact) -> some View {
        Section("Debug — Identity") {
            LabeledContent("localID", value: contact.localID)
            LabeledContent("Contact Type", value: contact.contactType.rawValue)
            LabeledContent("Image Available", value: contact.imageDataAvailable ? "yes" : "no")
            if let uuid = service.guessWhoUUID(in: contact) {
                LabeledContent("GuessWho UUID", value: uuid)
            } else if let reason = sidecarUnavailableReason {
                LabeledContent("GuessWho UUID", value: "none — \(reason)")
            } else {
                LabeledContent("GuessWho UUID", value: "none")
            }
        }

        let guessWhoURLs = contact.urlAddresses.filter {
            $0.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
        }
        if !guessWhoURLs.isEmpty {
            Section("Debug — GuessWho URLs") {
                ForEach(Array(guessWhoURLs.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedLabel(item.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }

        Section("Debug — Reconcile") {
            if let outcome = reconcileOutcome {
                LabeledContent("Assigned UUID", value: outcome.assignedUUID ?? "—")
                LabeledContent("Merged loser UUIDs",
                               value: outcome.mergedLoserUUIDs.isEmpty ? "—" : outcome.mergedLoserUUIDs.joined(separator: ", "))
                LabeledContent("Removed malformed URLs",
                               value: outcome.removedMalformedURLs.isEmpty ? "—" : outcome.removedMalformedURLs.joined(separator: ", "))
                LabeledContent("Rewritten link IDs",
                               value: outcome.rewrittenLinkIDs.isEmpty ? "—" : outcome.rewrittenLinkIDs.map(\.uuidString).joined(separator: ", "))
                if !outcome.errors.isEmpty {
                    ForEach(outcome.errors, id: \.self) { err in
                        Text(err).foregroundStyle(.red)
                    }
                }
            } else if let error = reconcileError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Reconciling…").foregroundStyle(.secondary)
            }
        }

        Section("Debug — Sidecar") {
            if let sidecar {
                LabeledContent("Entity ID", value: sidecar.entityID)
                LabeledContent("Schema Version", value: String(sidecar.schemaVersion))
                LabeledContent("Cells Dropped On Decode", value: String(sidecar.cellsDroppedOnDecode))
                if sidecar.fields.isEmpty {
                    Text("No fields").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(sidecar.fields.keys).sorted(), id: \.self) { name in
                        LabeledContent(name, value: cellDescription(sidecar.fields[name]))
                    }
                }
            } else {
                Text("No sidecar").foregroundStyle(.secondary)
            }
        }
    }
    #endif

    // MARK: - Loading & reconcile

    private var sidecarUnavailableReason: String? {
        if case .unavailable(let reason) = service.sidecarLocation { return reason }
        return nil
    }

    private var isSidecarStorageUnavailable: Bool {
        if case .unavailable = service.sidecarLocation { return true }
        return false
    }

    private func loadContact() async {
        let loaded = service.fetchAll().first { $0.localID == localID }
        contact = loaded
        if let loaded {
            sidecar = service.sidecar(for: loaded)
            let uuid = service.guessWhoUUID(in: loaded)
            if let uuid {
                // Rebuild the store if the contact's GuessWho UUID changed
                // since last load — a Case D reconcile picks a winner UUID
                // and deletes the loser's sidecar, so a store still bound
                // to the loser would read/write a dead file.
                if notesStore?.contactUUID != uuid {
                    notesStore = NotesStore(service: service, contactUUID: uuid)
                } else {
                    notesStore?.reload()
                }
            } else {
                notesStore = nil
            }
        }
    }

    private func performReconcile() async {
        guard !isSidecarStorageUnavailable else {
            reconcileError = sidecarUnavailableReason ?? "Sidecar storage unavailable"
            return
        }
        do {
            let result = try service.reconcile(localID: localID)
            reconcileOutcome = result
            reconcileError = nil
            await loadContact()
        } catch {
            reconcileError = "\(error)"
        }
    }

    // MARK: - Notes

    private func beginEdit(_ note: ContactNote) {
        // Tapping a different row mid-edit commits the prior one first.
        if let editingID, editingID != note.id {
            commitRowEditIfChanged()
        }
        editingID = note.id
        draftBody = note.body
        editStartSnapshot = note.body
        noteFocus = .row(note.id)
    }

    private func deleteNote(_ id: UUID) {
        if editingID == id {
            editingID = nil
            draftBody = ""
            editStartSnapshot = ""
            if case .row(let focused) = noteFocus, focused == id {
                noteFocus = nil
            }
        }
        notesStore?.deleteNote(id)
    }

    private func commitActiveEdit() {
        switch noteFocus {
        case .newNote:
            commitNewNote()
        case .row:
            commitRowEditIfChanged()
        case .none:
            break
        }
        noteFocus = nil
    }

    private func commitNewNote() {
        let body = newNoteText
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let notesStore else { return }
        notesStore.addNote(body: body)
        newNoteText = ""
    }

    private func commitRowEditIfChanged() {
        guard let id = editingID else { return }
        let proposed = draftBody
        let snapshot = editStartSnapshot
        editingID = nil
        draftBody = ""
        editStartSnapshot = ""
        if proposed == snapshot { return }
        notesStore?.editNote(id, newBody: proposed)
    }

    // MARK: - Formatting

    private func localizedLabel(_ raw: String) -> String {
        if raw.isEmpty { return "other" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
    }

    private func formatPostalAddress(_ address: PostalAddress) -> String {
        let cn = CNMutablePostalAddress()
        cn.street = address.street
        cn.subLocality = address.subLocality
        cn.city = address.city
        cn.subAdministrativeArea = address.subAdministrativeArea
        cn.state = address.state
        cn.postalCode = address.postalCode
        cn.country = address.country
        cn.isoCountryCode = address.isoCountryCode
        return CNPostalAddressFormatter.string(from: cn, style: .mailingAddress)
    }

    private func formatDateComponents(_ components: DateComponents) -> String {
        if let date = Calendar(identifier: .gregorian).date(from: components) {
            let style = Date.FormatStyle()
                .year(.defaultDigits)
                .month(.abbreviated)
                .day(.defaultDigits)
            return date.formatted(style)
        }
        var parts: [String] = []
        if let y = components.year { parts.append(String(y)) }
        if let m = components.month { parts.append(String(format: "%02d", m)) }
        if let d = components.day { parts.append(String(format: "%02d", d)) }
        return parts.isEmpty ? "—" : parts.joined(separator: "-")
    }

    private func socialProfileLabel(_ labeled: LabeledSocialProfile) -> String {
        // The CN-provided per-profile label is usually empty; the service
        // (twitter, linkedin, …) is the meaningful identifier here.
        let service = labeled.value.service
        if !labeled.label.isEmpty {
            return localizedLabel(labeled.label)
        }
        if !service.isEmpty {
            return service
        }
        return "social"
    }

    private func socialProfileValue(_ profile: SocialProfile) -> String {
        if !profile.username.isEmpty { return profile.username }
        if !profile.urlString.isEmpty { return profile.urlString }
        if !profile.userIdentifier.isEmpty { return profile.userIdentifier }
        return "—"
    }

    private func instantMessageLabel(_ labeled: LabeledInstantMessageAddress) -> String {
        let service = labeled.value.service
        if !labeled.label.isEmpty {
            return localizedLabel(labeled.label)
        }
        if !service.isEmpty {
            return service
        }
        return "im"
    }

    private func cellDescription(_ cell: SidecarCell?) -> String {
        guard let cell else { return "—" }
        if cell.deletedAt != nil { return "(deleted)" }
        return jsonValueDescription(cell.value)
    }

    private func jsonValueDescription(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return String(n)
        case .string(let s): return s
        case .array, .object:
            if let data = try? JSONEncoder().encode(value),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "(complex)"
        }
    }
}

private struct NotesSection: View {
    let store: NotesStore
    @Binding var newNoteText: String
    @Binding var editingID: UUID?
    @Binding var draftBody: String
    var noteFocus: FocusState<ContactDetailView.NoteFocus?>.Binding
    let beginEdit: (ContactNote) -> Void
    let deleteNote: (UUID) -> Void

    var body: some View {
        Section("Notes") {
            ForEach(store.notes, id: \.id) { note in
                row(for: note)
            }
            .onDelete { offsets in
                let ids = offsets.map { store.notes[$0].id }
                for id in ids { deleteNote(id) }
            }

            TextEditor(text: $newNoteText)
                .frame(minHeight: 32)
                .focused(noteFocus, equals: .newNote)
        }
    }

    @ViewBuilder
    private func row(for note: ContactNote) -> some View {
        if editingID == note.id {
            TextEditor(text: $draftBody)
                .frame(minHeight: 44)
                .focused(noteFocus, equals: .row(note.id))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.body)
                HStack(spacing: 6) {
                    Text(note.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if note.modifiedAt > note.createdAt {
                        Text("edited")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                beginEdit(note)
            }
            .contextMenu {
                Button("Delete", role: .destructive) {
                    deleteNote(note.id)
                }
            }
        }
    }
}
