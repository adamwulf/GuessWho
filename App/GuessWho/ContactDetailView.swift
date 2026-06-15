import SwiftUI
import GuessWhoSync

struct ContactDetailView: View {
    @Environment(SyncService.self) private var service

    let localID: String

    @State private var contact: Contact?
    @State private var sidecar: SidecarEnvelope?
    @State private var notesStore: NotesStore?
    @State private var isReconciling = false
    @State private var showConfirmReconcile = false
    @State private var outcome: ReconcileOutcomeWrapper?
    #if DEBUG
    @State private var debugError: String?
    #endif

    var body: some View {
        Form {
            if let contact {
                Section("Name") {
                    LabeledContent("Display", value: displayName(for: contact))
                    if !contact.givenName.isEmpty {
                        LabeledContent("Given", value: contact.givenName)
                    }
                    if !contact.familyName.isEmpty {
                        LabeledContent("Family", value: contact.familyName)
                    }
                    if !contact.organizationName.isEmpty {
                        LabeledContent("Organization", value: contact.organizationName)
                    }
                }

                Section("Identity") {
                    LabeledContent("localID", value: contact.localID)
                    if let uuid = service.guessWhoUUID(in: contact) {
                        LabeledContent("GuessWho UUID", value: uuid)
                    } else if let reason = sidecarUnavailableReason {
                        Text("No GuessWho UUID. Reconcile is unavailable: \(reason)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No GuessWho UUID. Tap Reconcile to assign one on this device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let notesStore {
                    NotesSection(store: notesStore)
                }

                if let sidecar {
                    Section("Sidecar Fields") {
                        if sidecar.fields.isEmpty {
                            Text("(empty)").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(sidecar.fields.keys).sorted(), id: \.self) { name in
                                LabeledContent(name, value: cellDescription(sidecar.fields[name]))
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showConfirmReconcile = true
                    } label: {
                        if isReconciling {
                            HStack {
                                ProgressView()
                                Text("Reconciling…")
                            }
                        } else {
                            Text("Reconcile this contact")
                        }
                    }
                    .disabled(isReconciling || isSidecarStorageUnavailable)
                } footer: {
                    Text("Reconcile assigns a GuessWho UUID if missing, merges duplicate UUIDs, and removes malformed GuessWho URLs. Other contacts are untouched.")
                }

                #if DEBUG
                Section {
                    Button("Write debug field") {
                        writeDebugField()
                    }
                    .disabled(service.guessWhoUUID(in: contact) == nil || isSidecarStorageUnavailable)
                    if let debugError {
                        Text(debugError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Writes a sidecar field 'lastReconciledAt' with the current ISO8601 timestamp. A JSON file should appear in the iCloud Documents folder. Disabled until this contact has a GuessWho UUID.")
                }
                #endif
            } else {
                ProgressView()
            }
        }
        .navigationTitle(contact.map { displayName(for: $0) } ?? "Contact")
        .task {
            await loadContact()
        }
        .confirmationDialog(
            "Reconcile this contact?",
            isPresented: $showConfirmReconcile,
            titleVisibility: .visible
        ) {
            Button("Reconcile", role: .destructive) {
                Task { await performReconcile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This may add or remove GuessWho URLs on this contact and merge any duplicate GuessWho sidecars. No other contact fields are modified.")
        }
        .sheet(item: $outcome) { wrapper in
            ReconcileOutcomeView(outcome: wrapper.outcome) {
                outcome = nil
            }
        }
    }

    private var isSidecarStorageUnavailable: Bool {
        if case .unavailable = service.sidecarLocation { return true }
        return false
    }

    private var sidecarUnavailableReason: String? {
        if case .unavailable(let reason) = service.sidecarLocation { return reason }
        return nil
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

    #if DEBUG
    private func writeDebugField() {
        guard let contact, let uuid = service.guessWhoUUID(in: contact) else { return }
        debugError = nil
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            try service.setField("lastReconciledAt", value: .string(stamp), forContactUUID: uuid)
            sidecar = service.sidecar(for: contact)
        } catch {
            debugError = "Write failed: \(error.localizedDescription)"
        }
    }
    #endif

    private func performReconcile() async {
        isReconciling = true
        defer { isReconciling = false }
        do {
            let result = try service.reconcile(localID: localID)
            outcome = ReconcileOutcomeWrapper(outcome: result)
            await loadContact()
        } catch {
            outcome = ReconcileOutcomeWrapper(outcome: .init(
                localID: localID,
                assignedUUID: nil,
                mergedLoserUUIDs: [],
                removedMalformedURLs: [],
                errors: ["\(error)"]
            ))
        }
    }

    private func displayName(for contact: Contact) -> String {
        let personName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        if !personName.isEmpty { return personName }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if !contact.nickname.isEmpty { return contact.nickname }
        return "(Unnamed)"
    }

    private func cellDescription(_ cell: SidecarCell?) -> String {
        guard let cell else { return "—" }
        switch cell {
        case .value(let value, _, _):
            return jsonValueDescription(value)
        case .tombstone:
            return "(deleted)"
        }
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

    // Focus identity for the row currently in edit mode. nil means no row
    // is editing. The bottom "new note" editor uses its own focus state so
    // editing a row doesn't fight with creating a new one.
    private enum EditFocus: Hashable {
        case row(UUID)
    }

    @FocusState private var editFocus: EditFocus?
    @State private var editingID: UUID?
    @State private var draftBody: String = ""
    // The body captured at edit-start, used by §12.5's no-op-tap rule:
    // commit is a no-op only when the draft is unchanged from this
    // snapshot — never the current on-disk value. This matters when a
    // reconcile lands mid-edit and rewrites the on-disk body — a user
    // who only inspected must not silently win LWW against the
    // reconciled-in change.
    @State private var editStartSnapshot: String = ""
    @State private var newNoteText: String = ""
    @FocusState private var newNoteFocused: Bool

    var body: some View {
        Section("Notes") {
            if store.notes.isEmpty {
                Text("No notes yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.notes, id: \.id) { note in
                    row(for: note)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.notes[$0].id }
                    for id in ids {
                        if editingID == id {
                            cancelEdit()
                        }
                        store.deleteNote(id)
                    }
                }
            }

            HStack(alignment: .top) {
                TextField("Add a note", text: $newNoteText, axis: .vertical)
                    .focused($newNoteFocused)
                    .submitLabel(.send)
                    .onSubmit(submitNewNote)
                Button {
                    submitNewNote()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderless)
                .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func row(for note: ContactNote) -> some View {
        if editingID == note.id {
            TextEditor(text: $draftBody)
                .frame(minHeight: 44)
                .focused($editFocus, equals: .row(note.id))
                .onChange(of: editFocus) { _, newValue in
                    if newValue != .row(note.id), editingID == note.id {
                        commitEditIfChanged()
                    }
                }
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
        }
    }

    private func beginEdit(_ note: ContactNote) {
        if let editingID, editingID != note.id {
            commitEditIfChanged()
        }
        editingID = note.id
        draftBody = note.body
        editStartSnapshot = note.body
        editFocus = .row(note.id)
    }

    private func commitEditIfChanged() {
        guard let id = editingID else { return }
        let proposed = draftBody
        editingID = nil
        draftBody = ""
        let snapshot = editStartSnapshot
        editStartSnapshot = ""
        if proposed == snapshot { return }
        store.editNote(id, newBody: proposed)
    }

    private func cancelEdit() {
        editingID = nil
        draftBody = ""
        editStartSnapshot = ""
        editFocus = nil
    }

    private func submitNewNote() {
        let body = newNoteText
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addNote(body: body)
        newNoteText = ""
        newNoteFocused = false
    }
}

private struct ReconcileOutcomeWrapper: Identifiable {
    let id = UUID()
    let outcome: IdentityReconcileReport.ContactOutcome
}

private struct ReconcileOutcomeView: View {
    let outcome: IdentityReconcileReport.ContactOutcome
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Result") {
                    LabeledContent("localID", value: outcome.localID)
                    if let uuid = outcome.assignedUUID {
                        LabeledContent("Assigned UUID", value: uuid)
                    } else {
                        Text("No new UUID assigned.")
                    }
                }
                if !outcome.mergedLoserUUIDs.isEmpty {
                    Section("Merged loser UUIDs") {
                        ForEach(outcome.mergedLoserUUIDs, id: \.self) { Text($0) }
                    }
                }
                if !outcome.removedMalformedURLs.isEmpty {
                    Section("Removed malformed URLs") {
                        ForEach(outcome.removedMalformedURLs, id: \.self) { Text($0) }
                    }
                }
                if !outcome.errors.isEmpty {
                    Section("Errors") {
                        ForEach(outcome.errors, id: \.self) {
                            Text($0).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Reconcile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
    }
}
