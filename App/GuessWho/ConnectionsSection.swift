import SwiftUI
import GuessWhoSync

/// One action in the shared bottom row used by entity detail pages. Keeping
/// the row's layout here makes contacts, events, and places expose linking in
/// the same predictable location without coupling their sheet state.
struct DetailFooterAction {
    let title: String
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void
}

/// Full-width icon-and-caption actions separated by dividers. Hosts provide
/// the actions because each detail page owns its picker presentation state.
struct DetailActivityFooter: View {
    let actions: [DetailFooterAction]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider()
                }

                Button(action: item.action) {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.title3)
                        Text(item.title)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.isDisabled)
            }
        }
        .listRowInsets(EdgeInsets())
        .centeredRowContent()
    }
}

/// A minimal flow layout: places its subviews left-to-right and wraps to a new
/// line when the next subview would overflow the proposed width. It renders a
/// link's participant names as a naturally-wrapping run of independently
/// tappable buttons. A single participant lays out exactly like a plain label,
/// so the one-name row is visually unchanged (`LinkParticipantNames` only
/// reaches for this layout when there is more than one name).
struct WrappingNameFlow: Layout {
    /// Horizontal gap between items on a line. Zero because the comma-and-space
    /// that separates names is baked into each name's own text.
    var horizontalSpacing: CGFloat = 0
    /// Vertical gap between wrapped lines.
    var verticalSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = layoutLines(subviews: subviews, maxWidth: maxWidth)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(CGFloat.zero) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = layoutLines(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }

    private struct FlowLine {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Group subview indices into lines that each fit within `maxWidth`. Always
    /// keeps at least one item per line so a single over-wide name still places
    /// (it clips rather than vanishing — contact names are short in practice).
    private func layoutLines(subviews: Subviews, maxWidth: CGFloat) -> [FlowLine] {
        var lines: [FlowLine] = []
        var current = FlowLine()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width
            if !current.indices.isEmpty, projected > maxWidth {
                lines.append(current)
                current = FlowLine()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = current.indices.count == 1
                    ? size.width
                    : current.width + horizontalSpacing + size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

/// Renders a link's far participants as a naturally-wrapping run of
/// comma-separated names. Each resolved contact is an independently tappable
/// button that pushes its detail; an unresolved endpoint (kept as `nil` by the
/// package projection) reads "(Unknown contact)" in secondary text. A single
/// participant renders exactly like the old one-name row (a plain tinted button
/// laid out normally so a long name still wraps); multiple participants use the
/// wrapping flow above.
struct LinkParticipantNames: View {
    let contacts: [Contact?]
    @Environment(\.pushContactReference) private var pushContactReference

    var body: some View {
        // An empty projection still shows a single unknown row rather than
        // rendering nothing, so a link with no resolvable far contact is visible.
        let items = contacts.isEmpty ? [Contact?.none] : contacts
        if items.count == 1 {
            nameView(items[0], isLast: true)
        } else {
            WrappingNameFlow {
                ForEach(Array(items.enumerated()), id: \.offset) { index, contact in
                    nameView(contact, isLast: index == items.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func nameView(_ contact: Contact?, isLast: Bool) -> some View {
        let separator = isLast ? "" : ", "
        if let contact {
            Button {
                pushContactReference(ContactReference(id: contact.contactID))
            } label: {
                Text(contact.displayName + separator)
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        } else {
            Text("(Unknown contact)" + separator)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

struct LinkRow: View {
    let link: ContactLink
    /// The link's far contact participants (one for a plain link, several for a
    /// grouped link that shares this note). `nil` slots are unresolved contacts,
    /// preserved by the package projection.
    let otherContacts: [Contact?]
    let isEditing: Bool
    @Binding var draftNote: String
    var noteFocus: FocusState<ContactDetailView.NoteFocus?>.Binding
    let focusValue: ContactDetailView.NoteFocus
    let onBeginEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ActivityRowLayout {
            leadingAvatar
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                LinkParticipantNames(contacts: otherContacts)
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

    // Leading column: the FIRST resolved participant's thumbnail avatar
    // (initials-circle fallback), keeping the single 20pt circular footprint for
    // grouped links too. When no participant resolves, a generic person glyph in
    // the same footprint keeps known and unknown rows aligned.
    @ViewBuilder
    private var leadingAvatar: some View {
        if let first = otherContacts.compactMap({ $0 }).first {
            ContactAvatar(contact: first, diameter: 20)
        } else {
            UnknownContactAvatar(diameter: 20)
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
    /// Which record type the picker offers: `.person` for "Link Contact",
    /// `.organization` for "Link Org". Both produce the same `Link` record —
    /// an organization is a `Contact` — so this only filters the picker and
    /// swaps the copy.
    let kind: ContactType
    /// Hands back the chosen far ContactIDs (not bare UUIDs) and the one shared
    /// note. The store's async `addLink(to:note:)` resolves-or-mints every
    /// endpoint and writes ONE grouped link. Returns `true` on success; `false`
    /// keeps the sheet open with the selection and note intact so the user can
    /// retry.
    let onSave: (_ others: [ContactID], _ note: String) async -> Bool

    @State private var noteText: String = ""
    // Picker selection (ordered so a grouped link keeps the tap order). A
    // `.record` points at a real contact's ContactID; a `.phantom` points at a
    // company that has no record yet (the org picker only) — its record is
    // created on save so the link has a real endpoint. Never a raw localID: the
    // app never uses localID as an identity/selection token.
    @State private var selections: [Selection] = []
    @State private var pickerSearch: String = ""
    @State private var eligible: [EligibleContact] = []
    @State private var didLoad = false
    // Guards the async create-then-link path so Save can't fire twice.
    @State private var isSaving = false

    private enum Selection: Hashable {
        case record(ContactID)
        case phantom(key: String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextField("Note (optional)", text: $noteText, axis: .vertical)
                }

                Section(kind == .organization ? "Organizations" : "Contacts") {
                    if !didLoad {
                        ProgressView()
                    } else if eligible.isEmpty {
                        ContentUnavailableView(
                            kind == .organization ? "No Organizations" : "No Contacts",
                            systemImage: kind == .organization
                                ? "building.2"
                                : "person.crop.circle.badge.questionmark",
                            description: Text(
                                kind == .organization
                                    ? "No organizations are available to link."
                                    : "No other contacts are available to link."
                            )
                        )
                    } else {
                        ForEach(filtered(eligible: eligible), id: \.id) { entry in
                            Button {
                                toggle(entry.selection)
                            } label: {
                                HStack {
                                    Text(entry.contact.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selections.contains(entry.selection) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                        }
                    }
                }
            }
            .keyboardDismissible()
            .searchable(
                text: $pickerSearch,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: kind == .organization ? "Search organizations" : "Search contacts"
            )
            .navigationTitle("Add Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Disabled during the async phantom create-then-link so a
                    // late Cancel can't dismiss while that write is still in
                    // flight (the Task would otherwise finish the create + link
                    // anyway — Cancel would not actually cancel).
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(selections.isEmpty || isSaving)
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
        /// The row's display + search contact: a real record, or a name-only
        /// synthesized organization for a phantom entry.
        let contact: Contact
        let selection: Selection
        var id: Selection { selection }
    }

    private func loadEligibleContacts() async -> [EligibleContact] {
        var result: [EligibleContact] = []
        for contact in repository.contacts {
            // Only records of the requested type: "Link Contact" offers people,
            // "Link Org" offers organizations. Skip the contact we're linking
            // from; everything else of that type is eligible. Exclude by
            // ContactID (effective GuessWho identity), not a raw guessWhoUUID
            // compare. The link target's UUID is resolved on save inside the
            // link WRITE, so we don't precompute a UUID per row.
            guard contact.contactType == kind else { continue }
            let id = contact.contactID
            if id == currentContactID { continue }
            result.append(EligibleContact(contact: contact, selection: .record(id)))
        }
        // The org picker ALSO offers phantom organizations — companies named on
        // people that have no record of their own yet. A link needs a real
        // endpoint, so selecting one creates the record on save (see `save()`).
        // Read the query-independent accessor so the list's own search/filter
        // can't hide entries; this sheet applies its own `filtered(...)`.
        if kind == .organization {
            for phantom in repository.phantomOrganizations(matching: "") {
                let synthetic = Contact(contactType: .organization, organizationName: phantom.displayName)
                result.append(EligibleContact(contact: synthetic, selection: .phantom(key: phantom.key)))
            }
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

    /// Add or remove `selection` from the ordered selection set.
    private func toggle(_ selection: Selection) {
        if let index = selections.firstIndex(of: selection) {
            selections.remove(at: index)
        } else {
            selections.append(selection)
        }
    }

    private func save() {
        guard !selections.isEmpty, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            // Resolve every selection to a real ContactID first. A `.record`
            // already is one; a `.phantom` has no record to point a link at, so
            // create (or reuse) the organization here — either way the grouped
            // link gets a real endpoint and no duplicate org is minted on a race.
            var resolved: [ContactID] = []
            for selection in selections {
                switch selection {
                case .record(let id):
                    resolved.append(id)
                case .phantom(let key):
                    // Display name comes from the eligible row (canonical spelling).
                    let name = eligible.first { $0.selection == selection }?.contact.displayName ?? key
                    do {
                        if let existing = repository.organizationContact(named: name) {
                            resolved.append(existing.contactID)
                        } else {
                            let created = try await repository.createContact(
                                Contact(contactType: .organization, organizationName: name)
                            )
                            resolved.append(created.contactID)
                        }
                    } catch {
                        // Keep the sheet open with the selection + note intact so
                        // the user can retry; the failure surfaces through the
                        // host store's own error path.
                        isSaving = false
                        return
                    }
                }
            }
            // ONE grouped link write for the whole selection. On failure keep the
            // draft (selection + note) so the user can retry or pick differently.
            if await onSave(resolved, noteText) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}
