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
    /// Classifies this link relative to the opened `contactID`. Returns nil if
    /// the contact is neither endpoint (shouldn't happen for links surfaced
    /// from `links(at:)`, defensive guard).
    ///
    /// NO app-side identity compare: the identity comparison lives in the
    /// package via `SidecarKey.matches(_:)`, which compares the endpoint key
    /// against `contactID.guessWhoID` (a `package` field the app can't read).
    /// This method only READS the package's already-fetched `SidecarKey`
    /// endpoints (`endpointA`/`endpointB`) to label which end is the far
    /// contact — it constructs no key and reads no bare UUID.
    func direction(for contactID: ContactID) -> LinkDirection? {
        if endpointA.matches(contactID) { return .outgoing(other: endpointB) }
        if endpointB.matches(contactID) { return .incoming(other: endpointA) }
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
        ActivityRowLayout {
            leadingAvatar
        } content: {
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

    // Leading column: the resolved contact's thumbnail avatar (initials-circle
    // fallback). The unknown-contact case shows a generic person glyph in the
    // same 20pt circular footprint so known and unknown rows stay aligned.
    @ViewBuilder
    private var leadingAvatar: some View {
        if let other = otherContact {
            ContactAvatar(contact: other, diameter: 20)
        } else {
            UnknownContactAvatar(diameter: 20)
        }
    }

    @ViewBuilder
    private var otherContactView: some View {
        if let other = otherContact {
            Button {
                pushContactReference(ContactReference(id: other.contactID))
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

/// Shared row layout for the activity rows: a leading icon column (or empty
/// space, for note rows) and a content column. Keeps note text, connection
/// bodies, and event titles vertically aligned across types.
///
/// The leading column accepts either an SF Symbol name (the common case) or an
/// arbitrary view (used by connection rows to show a contact avatar). Both
/// occupy the same fixed-width column so every activity row stays aligned.
struct ActivityRowLayout<Leading: View, Content: View>: View {
    let leading: Leading
    let content: Content

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder content: () -> Content) {
        self.leading = leading()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
                .frame(width: 20)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ActivityRowLayout where Leading == _ActivityRowSymbol {
    /// Convenience for the common case: a secondary-tinted SF Symbol (or empty
    /// space when `systemImage` is nil) in the leading column.
    init(systemImage: String?, @ViewBuilder content: () -> Content) {
        self.init(leading: { _ActivityRowSymbol(systemImage: systemImage) }, content: content)
    }
}

/// Leading-column glyph used by the `systemImage:` convenience initializer.
struct _ActivityRowSymbol: View {
    let systemImage: String?

    var body: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }
}

struct AddLinkSheet: View {
    @Environment(ContactsRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    /// The opaque ContactID of the contact we're linking FROM. Keyed on the
    /// stable identity, not a bare UUID — the from-contact may be unreconciled,
    /// and the link WRITE reconciles + mints both endpoints internally, so no
    /// UUID is needed here.
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
            let id = contact.contactID
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
