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
                infoSection(contact)

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
    private func infoSection(_ contact: Contact) -> some View {
        // Mirror Apple's Contacts: one card with every populated field as
        // a label-above-value row, in roughly the same order Contacts uses.
        let rows = infoRows(for: contact)
        if !rows.isEmpty {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    InfoRow(label: row.label, value: row.value)
                }
            }
        }
    }

    private func infoRows(for contact: Contact) -> [InfoRowData] {
        var rows: [InfoRowData] = []

        // Names — only emit individual name parts that are actually
        // populated; skip the noisy ones (phonetic, prefix/suffix) when
        // empty, just like Contacts does.
        let nameParts: [(String, String)] = [
            ("prefix", contact.namePrefix),
            ("given", contact.givenName),
            ("middle", contact.middleName),
            ("family", contact.familyName),
            ("previous family", contact.previousFamilyName),
            ("suffix", contact.nameSuffix),
            ("nickname", contact.nickname),
            ("phonetic given", contact.phoneticGivenName),
            ("phonetic middle", contact.phoneticMiddleName),
            ("phonetic family", contact.phoneticFamilyName),
        ]
        for (label, value) in nameParts where !value.isEmpty {
            rows.append(.init(label: label, value: value))
        }

        // Work
        let workParts: [(String, String)] = [
            ("job title", contact.jobTitle),
            ("department", contact.departmentName),
            ("organization", contact.organizationName),
            ("phonetic organization", contact.phoneticOrganizationName),
        ]
        for (label, value) in workParts where !value.isEmpty {
            rows.append(.init(label: label, value: value))
        }

        // Phones, emails, URLs (user-facing only — guesswho:// lives in DEBUG)
        for item in contact.phoneNumbers {
            rows.append(.init(label: localizedLabel(item.label), value: item.value))
        }
        for item in contact.emailAddresses {
            rows.append(.init(label: localizedLabel(item.label), value: item.value))
        }
        for item in contact.urlAddresses where SidecarKey.parseGuessWhoContactURL(item.value) == nil {
            rows.append(.init(label: localizedLabel(item.label), value: item.value))
        }

        // Postal addresses
        for item in contact.postalAddresses {
            rows.append(.init(label: localizedLabel(item.label), value: formatPostalAddress(item.value)))
        }

        // Dates
        if let bday = contact.birthday {
            rows.append(.init(label: "birthday", value: formatDateComponents(bday)))
        }
        if let nonGreg = contact.nonGregorianBirthday {
            rows.append(.init(label: "non-gregorian birthday", value: formatDateComponents(nonGreg)))
        }
        for item in contact.dates {
            rows.append(.init(label: localizedLabel(item.label), value: formatDateComponents(item.value)))
        }

        // Social, IM, relations
        for item in contact.socialProfiles {
            rows.append(.init(label: socialProfileLabel(item), value: socialProfileValue(item.value)))
        }
        for item in contact.instantMessageAddresses {
            rows.append(.init(label: instantMessageLabel(item), value: item.value.username))
        }
        for item in contact.contactRelations {
            rows.append(.init(label: localizedLabel(item.label), value: item.value.name))
        }

        return rows
    }

    #if DEBUG
    @ViewBuilder
    private func debugSection(_ contact: Contact) -> some View {
        Section("Debug") {
            InfoRow(label: "localID", value: contact.localID, monospaced: true)
            InfoRow(label: "contact type", value: contact.contactType.rawValue)
            InfoRow(label: "image available", value: contact.imageDataAvailable ? "yes" : "no")

            if let uuid = service.guessWhoUUID(in: contact) {
                InfoRow(label: "guesswho uuid", value: uuid, monospaced: true)
            } else if let reason = sidecarUnavailableReason {
                InfoRow(label: "guesswho uuid", value: "none — \(reason)")
            } else {
                InfoRow(label: "guesswho uuid", value: "none")
            }

            let guessWhoURLs = contact.urlAddresses.filter {
                $0.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
            }
            ForEach(Array(guessWhoURLs.enumerated()), id: \.offset) { _, item in
                InfoRow(label: "guesswho url (\(localizedLabel(item.label)))", value: item.value, monospaced: true)
            }

            reconcileRows
            sidecarRows
        }
    }

    @ViewBuilder
    private var reconcileRows: some View {
        if let outcome = reconcileOutcome {
            InfoRow(label: "reconcile: assigned uuid", value: outcome.assignedUUID ?? "—", monospaced: outcome.assignedUUID != nil)
            InfoRow(
                label: "reconcile: merged loser uuids",
                value: outcome.mergedLoserUUIDs.isEmpty ? "—" : outcome.mergedLoserUUIDs.joined(separator: ", "),
                monospaced: !outcome.mergedLoserUUIDs.isEmpty
            )
            InfoRow(
                label: "reconcile: removed malformed urls",
                value: outcome.removedMalformedURLs.isEmpty ? "—" : outcome.removedMalformedURLs.joined(separator: ", "),
                monospaced: !outcome.removedMalformedURLs.isEmpty
            )
            InfoRow(
                label: "reconcile: rewritten link ids",
                value: outcome.rewrittenLinkIDs.isEmpty ? "—" : outcome.rewrittenLinkIDs.map(\.uuidString).joined(separator: ", "),
                monospaced: !outcome.rewrittenLinkIDs.isEmpty
            )
            ForEach(Array(outcome.errors.enumerated()), id: \.offset) { _, err in
                InfoRow(label: "reconcile error", value: err, valueColor: .red)
            }
        } else if let error = reconcileError {
            InfoRow(label: "reconcile error", value: error, valueColor: .red)
        } else {
            InfoRow(label: "reconcile", value: "running…")
        }
    }

    @ViewBuilder
    private var sidecarRows: some View {
        if let sidecar {
            InfoRow(label: "sidecar: entity id", value: sidecar.entityID, monospaced: true)
            InfoRow(label: "sidecar: schema version", value: String(sidecar.schemaVersion))
            InfoRow(label: "sidecar: cells dropped on decode", value: String(sidecar.cellsDroppedOnDecode))
            if sidecar.fields.isEmpty {
                InfoRow(label: "sidecar fields", value: "(none)")
            } else {
                ForEach(Array(sidecar.fields.keys).sorted(), id: \.self) { name in
                    InfoRow(label: "sidecar: \(name)", value: cellDescription(sidecar.fields[name]), monospaced: true)
                }
            }
        } else {
            InfoRow(label: "sidecar", value: "(none)")
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

private struct InfoRowData {
    let label: String
    let value: String
}

private struct InfoRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var valueColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .body)
                .foregroundStyle(valueColor ?? .primary)
                .textSelection(.enabled)
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
