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

struct LinkRow: View {
    let link: ContactLink
    let direction: LinkDirection
    let otherContact: Contact?
    let isEditing: Bool
    @Binding var draftNote: String
    var noteFocus: FocusState<ContactDetailView.NoteFocus?>.Binding
    let focusValue: ContactDetailView.NoteFocus
    let onBeginEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isEditing {
                editor
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
                otherContactView
            }
        }
    }

    @ViewBuilder
    private var otherContactView: some View {
        if let other = otherContact {
            NavigationLink(value: ContactReference(localID: other.localID)) {
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
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $draftNote, axis: .vertical)
                .focused(noteFocus, equals: focusValue)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Done", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
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
    @State private var selectedLocalID: String?
    @State private var pickerSearch: String = ""
    @State private var eligible: [EligibleContact] = []
    @State private var didLoad = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Note (optional)", text: $noteText, axis: .vertical)
                }

                Section("Contact") {
                    if !didLoad {
                        ProgressView()
                    } else if eligible.isEmpty {
                        ContentUnavailableView(
                            "No Contacts",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("No other contacts are available to link.")
                        )
                    } else {
                        ForEach(filtered(eligible: eligible), id: \.localID) { entry in
                            Button {
                                selectedLocalID = entry.localID
                            } label: {
                                HStack {
                                    Text(entry.contact.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedLocalID == entry.localID {
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

                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
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
                    Button("Save") { save() }
                        .disabled(selectedLocalID == nil)
                }
            }
            .task {
                if !didLoad {
                    eligible = loadEligibleContacts()
                    didLoad = true
                }
            }
        }
    }

    private struct EligibleContact {
        let contact: Contact
        let localID: String
        let existingUUID: String?
    }

    private func loadEligibleContacts() -> [EligibleContact] {
        var result: [EligibleContact] = []
        let target = currentContactUUID.lowercased()
        for contact in service.fetchAll() {
            let existing = service.guessWhoUUID(in: contact)
            if let existing, existing == target { continue }
            result.append(EligibleContact(
                contact: contact,
                localID: contact.localID,
                existingUUID: existing
            ))
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

    private func save() {
        guard let localID = selectedLocalID,
              let entry = eligible.first(where: { $0.localID == localID }) else { return }
        do {
            let toUUID: String
            if let existing = entry.existingUUID {
                toUUID = existing
            } else {
                _ = try service.reconcile(localID: localID)
                guard let fresh = service.fetchAll().first(where: { $0.localID == localID }),
                      let assigned = service.guessWhoUUID(in: fresh) else {
                    saveError = "Could not assign an identity to this contact."
                    return
                }
                toUUID = assigned
            }
            onSave(toUUID, noteText)
            dismiss()
        } catch {
            saveError = "Failed to save link: \(error.localizedDescription)"
        }
    }
}
