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
    ///
    /// IDENTITY CARVE-OUT (Stage 6e, Task C — blessed, NOT a defect): `uuid` is
    /// the OPENED contact's OWN reconciled `guessWhoID` (the Stage-5
    /// `repository.guessWhoID(in:)` value — a legitimate app-side UUID per 6b2's
    /// `contact(guessWhoID:)` ruling), used purely to label which end of this
    /// already-fetched `ContactLink` is the far contact. It READS the package's
    /// `SidecarKey` endpoints (`endpointA`/`endpointB`) and constructs NONE; it
    /// translates no identity. Moving this behind a resolved `links(for:)` API was
    /// assessed in 6e and rejected as more than modest — see the plan's Acceptance
    /// `LinkDirection` carve-out.
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
    let otherContact: Contact?
    let isEditing: Bool
    @Binding var draftNote: String
    var noteFocus: FocusState<ContactDetailView.NoteFocus?>.Binding
    let focusValue: ContactDetailView.NoteFocus
    let onBeginEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    // Bridge to the outer UIKit nav controller (iPhone shell) so the
    // related-contact row pushes a fresh ContactDetailView. See
    // `ReferenceNavigation.swift` for the env-closure defaults.
    @Environment(\.pushContactReference) private var pushContactReference
    // Needed to re-key the row's `Contact` to its opaque `ContactID` for the
    // navigation push — the app can't mint a ContactID itself.
    @Environment(ContactsRepository.self) private var repository

    var body: some View {
        ActivityRowLayout(systemImage: "person") {
            VStack(alignment: .leading, spacing: 4) {
                otherContactView
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
        }
        .contextMenu {
            Button {
                onBeginEdit()
            } label: {
                Label("Edit Note", systemImage: "pencil")
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var otherContactView: some View {
        if let other = otherContact {
            Button {
                pushContactReference(ContactReference(id: repository.contactID(for: other)))
            } label: {
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
            }
            Text(link.createdAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shared row layout for the merged Activity section: a leading icon column
/// (or empty space, for note rows) and a content column. Keeps note text,
/// connection bodies, and event titles vertically aligned across types.
struct ActivityRowLayout<Content: View>: View {
    let systemImage: String?
    let content: Content

    init(systemImage: String?, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AddLinkSheet: View {
    @Environment(ContactsRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    /// The opaque ContactID of the contact we're linking FROM. Keyed on the
    /// stable identity, not a bare UUID — the from-contact may be unreconciled
    /// (the gate dropped in 6d), and the link WRITE reconciles + mints both
    /// endpoints internally, so no UUID is needed here.
    let currentContactID: ContactID
    /// Hands back the far endpoint's ContactID (not a bare UUID): the store's
    /// async `addLink(to:note:)` resolves-or-mints both endpoints.
    let onSave: (_ other: ContactID, _ note: String) -> Void

    @State private var noteText: String = ""
    // Picker selection keyed on the opaque ContactID, not a raw localID — the
    // app never uses localID as an identity/selection token.
    @State private var selectedContactID: ContactID?
    @State private var pickerSearch: String = ""
    @State private var eligible: [EligibleContact] = []
    @State private var didLoad = false

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
                        ForEach(filtered(eligible: eligible), id: \.id) { entry in
                            Button {
                                selectedContactID = entry.id
                            } label: {
                                HStack {
                                    Text(entry.contact.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedContactID == entry.id {
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
                    Button("Save") { save() }
                        .disabled(selectedContactID == nil)
                }
            }
            .task {
                if !didLoad {
                    eligible = await loadEligibleContacts()
                    didLoad = true
                }
            }
        }
    }

    private struct EligibleContact {
        let contact: Contact
        let id: ContactID
    }

    private func loadEligibleContacts() async -> [EligibleContact] {
        var result: [EligibleContact] = []
        for contact in repository.contacts {
            // Skip the contact we're linking from; everything else is eligible.
            // Exclude by ContactID (effective GuessWho identity), not a raw
            // guessWhoUUID compare. The link target's UUID is resolved on save
            // inside the link WRITE, so we don't precompute a UUID per row.
            let id = repository.contactID(for: contact)
            if id == currentContactID { continue }
            result.append(EligibleContact(contact: contact, id: id))
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
        guard let selectedContactID else { return }
        // Hand the far endpoint's ContactID straight back — the link WRITE
        // (`ContactsRepository.addLink`) resolves-or-mints BOTH endpoints
        // internally, so there is no app-side reconcile here. Any write failure
        // surfaces through the store's reload, not this sheet.
        onSave(selectedContactID, noteText)
        dismiss()
    }
}
