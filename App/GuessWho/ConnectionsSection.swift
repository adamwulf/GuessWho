import SwiftUI
import GuessWhoSync

enum LinkDirection {
    case outgoing(other: SidecarKey)
    case incoming(other: SidecarKey)

    var other: SidecarKey {
        switch self {
        case .outgoing(let other), .incoming(let other): return other
        }
    }

    var isOutgoing: Bool {
        if case .outgoing = self { return true }
        return false
    }
}

extension ContactLink {
    /// Classifies this link relative to a contact UUID. Returns nil if the
    /// contact is neither endpoint (shouldn't happen for links surfaced
    /// from `links(at:)`, defensive guard).
    func direction(forContactUUID uuid: String) -> LinkDirection? {
        let target = uuid.lowercased()
        if endpointA.kind == .contact, endpointA.id == target {
            return .outgoing(other: endpointB)
        }
        if endpointB.kind == .contact, endpointB.id == target {
            return .incoming(other: endpointA)
        }
        return nil
    }
}

struct ConnectionsSection: View {
    let store: ContactLinksStore
    let contactUUID: String
    @Environment(SyncService.self) private var service

    @State private var editingID: UUID?
    @State private var draftNote: String = ""
    @State private var editStartSnapshot: String = ""
    @State private var showAddSheet = false
    @FocusState private var editingFocus: UUID?

    var body: some View {
        Section("Connections") {
            ForEach(store.links, id: \.id) { link in
                row(for: link)
            }
            .onDelete { offsets in
                let ids = offsets.map { store.links[$0].id }
                for id in ids { store.remove(id: id) }
            }

            Button {
                showAddSheet = true
            } label: {
                Label("Add Link", systemImage: "plus.circle")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddLinkSheet(currentContactUUID: contactUUID) { toUUID, note in
                store.addLink(toUUID: toUUID, note: note)
            }
        }
        .onDisappear {
            commitEditIfChanged()
        }
    }

    @ViewBuilder
    private func row(for link: ContactLink) -> some View {
        if let direction = link.direction(forContactUUID: contactUUID) {
            LinkRow(
                link: link,
                direction: direction,
                isEditing: editingID == link.id,
                draftNote: $draftNote,
                editingFocus: $editingFocus,
                onBeginEdit: { beginEdit(link) },
                onDelete: { store.remove(id: link.id) }
            )
        }
    }

    private func beginEdit(_ link: ContactLink) {
        if let editingID, editingID != link.id {
            commitEditIfChanged()
        }
        editingID = link.id
        draftNote = link.note
        editStartSnapshot = link.note
        editingFocus = link.id
    }

    private func commitEditIfChanged() {
        guard let id = editingID else { return }
        let proposed = draftNote
        let snapshot = editStartSnapshot
        editingID = nil
        draftNote = ""
        editStartSnapshot = ""
        if proposed == snapshot { return }
        store.setNote(id: id, note: proposed)
    }
}

private struct LinkRow: View {
    @Environment(SyncService.self) private var service

    let link: ContactLink
    let direction: LinkDirection
    let isEditing: Bool
    @Binding var draftNote: String
    var editingFocus: FocusState<UUID?>.Binding
    let onBeginEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isEditing {
                TextField("", text: $draftNote, axis: .vertical)
                    .focused(editingFocus, equals: link.id)
            } else {
                Button(action: onBeginEdit) {
                    noteAndTimestamp
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var header: some View {
        let endpoint = direction.other
        let symbol = direction.isOutgoing ? "arrow.right" : "arrow.left"
        let label = direction.isOutgoing ? "Introduced" : "Introduced By"

        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                otherContactView(endpoint: endpoint)
            }
        }
    }

    @ViewBuilder
    private func otherContactView(endpoint: SidecarKey) -> some View {
        if endpoint.kind == .contact, let other = service.contact(forGuessWhoUUID: endpoint.id) {
            NavigationLink(value: other.localID) {
                Text(other.displayName)
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        } else {
            Text("(Unknown contact)")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var noteAndTimestamp: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !link.note.isEmpty {
                Text(link.note)
            } else {
                Text("(no note)")
                    .foregroundStyle(.secondary)
                    .italic()
            }
            HStack(spacing: 6) {
                Text(link.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if link.modifiedAt > link.createdAt {
                    Text("edited")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AddLinkSheet: View {
    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let currentContactUUID: String
    let onSave: (_ toUUID: String, _ note: String) -> Void

    @State private var noteText: String = ""
    @State private var selectedContactUUID: String?
    @State private var pickerSearch: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Note (optional)", text: $noteText, axis: .vertical)
                }

                Section("Contact") {
                    let eligible = eligibleContacts()
                    if eligible.isEmpty {
                        ContentUnavailableView(
                            "No Eligible Contacts",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("No other contacts have a GuessWho identity yet. Open a contact to assign one.")
                        )
                    } else {
                        ForEach(filtered(eligible: eligible), id: \.localID) { entry in
                            Button {
                                selectedContactUUID = entry.uuid
                            } label: {
                                HStack {
                                    Text(entry.contact.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedContactUUID == entry.uuid {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $pickerSearch, prompt: "Search contacts")
            .navigationTitle("Add Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let toUUID = selectedContactUUID {
                            onSave(toUUID, noteText)
                            dismiss()
                        }
                    }
                    .disabled(selectedContactUUID == nil)
                }
            }
        }
    }

    private struct EligibleContact {
        let contact: Contact
        let uuid: String
        var localID: String { contact.localID }
    }

    private func eligibleContacts() -> [EligibleContact] {
        var result: [EligibleContact] = []
        let target = currentContactUUID.lowercased()
        for contact in service.fetchAll() {
            guard let uuid = service.guessWhoUUID(in: contact) else { continue }
            if uuid == target { continue }
            result.append(EligibleContact(contact: contact, uuid: uuid))
        }
        return result.sorted { lhs, rhs in
            lhs.contact.displayName.localizedCaseInsensitiveCompare(rhs.contact.displayName) == .orderedAscending
        }
    }

    private func filtered(eligible: [EligibleContact]) -> [EligibleContact] {
        let query = pickerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return eligible }
        return eligible.filter { $0.contact.matches(searchQuery: query) }
    }
}
