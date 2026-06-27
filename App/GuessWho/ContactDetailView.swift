import SwiftUI
import Contacts
import MapKit
import GuessWhoSync

struct ContactDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(ContactsRepository.self) private var repository
    @Environment(ContactPhotoLoader.self) private var photoLoader
    @Environment(FavoritesListStore.self) private var favoritesStore
    @Environment(\.dismiss) private var dismiss
    // Set by SceneDelegate when this view is pushed onto an iPhone
    // UIKit nav stack. Defaults to a no-op closure (see
    // `ReferenceNavigation.swift`), which is also what Catalyst gets
    // today — that matches Catalyst's pre-bridge silent behaviour.
    @Environment(\.pushContactReference) private var pushContactReference
    @Environment(\.pushEventReference) private var pushEventReference

    /// The view's identity is the opaque, package-vended `ContactID` — NEVER a
    /// raw `localID`. It is the nav identity the scene delegate hands in; the
    /// view resolves it to a `Contact` via `repository.contact(id:)`. Since 6b2
    /// made `contact(id:)` reconcile-stable (it falls back to the `ContactID`'s
    /// always-present `localID` when the captured token's `guessWhoID` is still
    /// nil after a first-write reconcile), the view re-loads off this same captured
    /// `id` and needs no separately-threaded `localID` token. The handful of
    /// contact-LIFECYCLE boundary calls that genuinely need a
    /// `CNContact.identifier` (edit/save/delete/fetch) read it from the loaded
    /// `Contact` at the call site.
    let id: ContactID

    @State private var contact: Contact?
    @State private var headerPhoto: UIImage?
    @State private var notesStore: NotesStore?
    @State private var fieldsStore: FieldsStore?
    @State private var linksStore: ContactLinksStore?
    @State private var eventLinks: [ContactLink] = []
    @State private var showingEventPicker = false
    // EventKit events where this contact appears as an attendee (matched by
    // any email on the contact card). Loaded async via SyncService on first
    // contact-load and on contact reload — separate from `eventLinks` which
    // are user-curated contact↔event links.
    @State private var recentEvents: [Event] = []
    // Monotonic token bumped at the start of every `reloadRecentEvents` call.
    // The async load captures the token at the call site and bails on result
    // assignment when it no longer matches — so a stale in-flight fetch (after
    // a navigation, a contact-emails edit, or rapid reloads) can't overwrite
    // the freshest result. Stronger than a localID-only check, which can't
    // distinguish two same-localID reloads in quick succession.
    @State private var recentEventsLoadID: UUID = UUID()
    @State private var showingAddLinkSheet = false
    @State private var showingNewNoteEditor = false
    @State private var editFetchErrorMessage: String?

    // Inline contact-edit state. Non-nil `editModel` means the detail view
    // has flipped into editing mode in-place (no sheet). The model is
    // seeded from a fresh package-owned edit fetch when the user taps Edit;
    // nilled out on Cancel/Save.
    @State private var editModel: ContactEditModel?
    @State private var isSavingEdit = false
    @State private var editSaveError: ContactEditModel.SaveErrorCategory?
    @State private var editDeleteError: ContactEditModel.SaveErrorCategory?
    // Owned ambient edit-mode for the editing list. Without an owned binding,
    // EditButton drives an unscoped \.editMode that stays .active after the
    // user exits contact-edit, leaking drag-handle/delete-circle affordances
    // into the read-only activity list. Reset to .inactive on every exit.
    @State private var editMode: EditMode = .inactive
    @State private var showDiscardConfirm = false
    @State private var showDeleteConfirm = false

    // Focus identity covers both the bottom new-note editor and any row
    // currently being edited. Hoisted here so a single nav-bar checkmark
    // can commit whichever edit is active and dismiss the keyboard.
    enum NoteFocus: Hashable {
        case newNote
        case noteRow(UUID)
        case linkRow(UUID)
    }
    @FocusState private var noteFocus: NoteFocus?
    @State private var newNoteText: String = ""
    @State private var editingNoteID: UUID?
    @State private var draftBody: String = ""
    // Sidecar-field edit state: the field being edited (presented in an alert)
    // and its working text.
    @State private var editingField: SidecarField?
    @State private var fieldDraft: String = ""
    // Body captured at edit-start, used by §12.5's no-op-tap rule: commit
    // is a no-op only when the draft is unchanged from this snapshot —
    // never the current on-disk value. Matters when a reconcile lands
    // mid-edit and rewrites the on-disk body.
    @State private var editStartSnapshot: String = ""

    @AppStorage(AppSettings.Key.debugModeEnabled) private var debugModeEnabled = AppSettings.Default.debugModeEnabled

    // Contact-link edit state (lifted from the old ConnectionsSection).
    @State private var editingLinkID: UUID?
    @State private var draftLinkNote: String = ""
    @State private var editLinkStartSnapshot: String = ""

    private var isEditingAnything: Bool {
        noteFocus != nil
    }

    private var isEditingContact: Bool {
        editModel != nil
    }

    private enum ActivityItem: Identifiable {
        case note(ContactNote)
        case connection(ContactLink)
        case event(ContactLink)

        var id: AnyHashable {
            switch self {
            case .note(let n): return AnyHashable("note-\(n.id)")
            case .connection(let l): return AnyHashable("conn-\(l.id)")
            case .event(let l): return AnyHashable("event-\(l.id)")
            }
        }

        var createdAt: Date {
            switch self {
            case .note(let n): return n.createdAt
            case .connection(let l), .event(let l): return l.createdAt
            }
        }

        var sortKey: (Date, String) {
            switch self {
            case .note(let n): return (n.createdAt, "n-\(n.id.uuidString)")
            case .connection(let l): return (l.createdAt, "c-\(l.id.uuidString)")
            case .event(let l): return (l.createdAt, "e-\(l.id.uuidString)")
            }
        }
    }

    private var activityItems: [ActivityItem] {
        var items: [ActivityItem] = []
        if let notesStore {
            items.append(contentsOf: notesStore.notes.map(ActivityItem.note))
        }
        if let linksStore {
            items.append(contentsOf: linksStore.links.map(ActivityItem.connection))
        }
        items.append(contentsOf: eventLinks.map(ActivityItem.event))
        return items.sorted { $0.sortKey < $1.sortKey }
    }

    var body: some View {
        Group {
            if let contact {
                loadedContent(contact)
            } else {
                // Centered loading state — hoisted out of the List so
                // it sits in the middle of the detail pane instead of
                // landing in the top-left as the first list row.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Width clamping is NOT applied to this Group: doing so would inset
        // the List (and therefore its scroll view) from the pane edges,
        // leaving inert dead space on the sides that doesn't scroll. Instead
        // the List stays full-bleed and each row clamps + centers its own
        // content to `ContactDetailLayout.maxContentWidth` (see
        // `centeredRowContent`), so the scrollable region reaches the pane
        // edges while the visible content stays in the same centered column.
        // macCatalyst only — see `loadedContent`.
        // The inline header (shown on every platform now) already renders the
        // name and subtitle, so an empty nav-bar title avoids showing the name
        // twice while keeping the toolbar itself (back button + Edit/star).
        .navigationTitle("")
        #if !targetEnvironment(macCatalyst)
        // Inline display mode so the empty title doesn't reserve large-title
        // space above the header on the pushed iPhone/iPad detail.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { cancelEdit() }
            Button("Keep Editing", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete contact?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Contact", role: .destructive) {
                Task { await performInlineDelete() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { editSaveError != nil },
                set: { if !$0 { editSaveError = nil } }
            ),
            presenting: editSaveError
        ) { category in
            Button("OK", role: .cancel) { editSaveError = nil }
            if category == .authorizationDenied {
                OpenContactsSettingsButton()
            }
        } message: { category in
            Text(category.saveFailureMessage)
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { editDeleteError != nil },
                set: { if !$0 { editDeleteError = nil } }
            ),
            presenting: editDeleteError
        ) { category in
            Button("OK", role: .cancel) { editDeleteError = nil }
            if category == .authorizationDenied {
                OpenContactsSettingsButton()
            }
        } message: { category in
            Text(category.deleteFailureMessage)
        }
        .alert("Couldn't open editor", isPresented: Binding(
            get: { editFetchErrorMessage != nil },
            set: { if !$0 { editFetchErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { editFetchErrorMessage = nil }
        } message: {
            Text(editFetchErrorMessage ?? "")
        }
        .task {
            // Just load the contact by its `ContactID` — no reconcile on open.
            // Reconcile is WRITE-ONLY (6f reverses the 6c detail-open reconcile):
            // displaying a contact needs no GuessWho URL, an unstamped contact
            // has no sidecar data to show (correct), and the FIRST write mints
            // via the package's resolve-or-mint primitive.
            await loadContact()
        }
        .task(id: contact?.contactID) {
            await loadHeaderPhoto()
        }
        .onDisappear {
            // Backstop for the edge-swipe-back gesture: the system pop
            // bypasses our custom back button, so commit here too. A no-op
            // if commitActiveEdit() already ran from a button tap.
            commitActiveEdit()
        }
    }

    @ViewBuilder
    private func loadedContent(_ contact: Contact) -> some View {
        // `.centeredRowContent()` is applied to each ROW's content view (inside
        // the section helpers below), NOT to the `Section`s here. A Section is a
        // structural list element, not a laid-out view, so `.frame(maxWidth:)`
        // on it does not reliably clamp row width; applied to the row content it
        // does. The List itself stays full-bleed so its scroll view reaches the
        // pane edges. See `centeredRowContent`.
        let list = List {
            Section {
                // Inline header on every platform: monogram + name + subtitle
                // read as a centered card, matching Apple's Contacts detail.
                // `.frame(maxWidth: .infinity)` centers it within the row on all
                // platforms; `.centeredRowContent(alignment: .center)` adds the
                // 560 column clamp on Catalyst (a no-op elsewhere).
                headerView(contact)
                    .frame(maxWidth: .infinity)
                    .centeredRowContent(alignment: .center)
                    .listRowInsets(EdgeInsets(top: 24, leading: 0, bottom: 16, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isEditingContact {
                editingSections
            } else {
                infoSection(contact)

                sidecarFieldsSection

                referencedBySection(contact)

                recentEventsSection

                activitySection

                if debugModeEnabled {
                    debugSection(contact)
                }

                Section { activityFooter }
            }
        }
        // Inject the owned editMode binding so EditButton drives this view's
        // own .editMode state instead of an ambient one we can't tear down.
        // Reset to .inactive happens on every contact-edit exit path.
        #if targetEnvironment(macCatalyst)
        list
            .listStyle(.inset)
            .environment(\.editMode, $editMode)
            .modifier(EditFieldAlert(
                field: $editingField, draft: $fieldDraft,
                onSave: { f, value in Task { await fieldsStore?.editField(f.id, value: value) } }
            ))
        #else
        list
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .modifier(EditFieldAlert(
                field: $editingField, draft: $fieldDraft,
                onSave: { f, value in Task { await fieldsStore?.editField(f.id, value: value) } }
            ))
        #endif
    }

    /// Editor section stack used when `isEditingContact` is true. Reuses
    /// the same row components as the sheet editor. The binding falls
    /// back to a throwaway empty model — never hit in practice because
    /// the call site is gated on `editModel != nil`, but a nil-coalesce
    /// keeps the binding total without a runtime trap.
    @ViewBuilder
    private var editingSections: some View {
        let binding = Binding<ContactEditModel>(
            get: { editModel ?? ContactEditModel(original: contact ?? Contact()) },
            set: { editModel = $0 }
        )
        NameFieldsRow(model: binding)
        OrgFieldsRow(model: binding)
        PhoneRow(model: binding)
        EmailRow(model: binding)
        URLRow(model: binding)
        PostalAddressRow(model: binding)
        BirthdayRow(model: binding)
        DateRow(model: binding)
        RelationRow(model: binding)
        SocialProfileRow(model: binding)
        IMRow(model: binding)
        PhoneticNameRow(model: binding)
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Contact")
                    Spacer()
                }
            }
            .disabled(isSavingEdit)
            .centeredRowContent()
        }
    }

    // MARK: - Inline edit (no sheet — flips this view into edit mode)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditingContact {
            editingToolbarContent
        }
        if !isEditingContact, isEditingAnything {
            inlineNoteDoneToolbarContent
        }
        if !isEditingContact, !isEditingAnything, contact != nil {
            readOnlyToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var editingToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if editModel?.isDirty == true {
                    showDiscardConfirm = true
                } else {
                    cancelEdit()
                }
            }
            .disabled(isSavingEdit)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                Task { await performInlineSave() }
            }
            .disabled(editModel?.isDirty != true || isSavingEdit)
        }
    }

    @ToolbarContentBuilder
    private var inlineNoteDoneToolbarContent: some ToolbarContent {
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

    @ToolbarContentBuilder
    private var readOnlyToolbarContent: some ToolbarContent {
        // Star sits BEFORE Edit so the toolbar reads star, Edit. Always
        // enabled — favoriting a never-touched contact now reconciles + mints
        // the GuessWho UUID transparently (the write resolves-or-mints
        // internally), so there is no gate on an existing UUID.
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: isContactFavorited ? "star.fill" : "star")
            }
            .accessibilityLabel(isContactFavorited ? "Unfavorite" : "Favorite")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Edit") {
                Task { await beginInlineEdit() }
            }
        }
    }

    private func beginInlineEdit() async {
        do {
            guard let loaded = try await repository.editableContact(id: id) else {
                editFetchErrorMessage = "Contact could not be found."
                return
            }
            editModel = ContactEditModel(original: loaded)
            // Pin the list into edit mode for the duration of contact-edit so
            // .onMove drag handles appear on multi-value rows without needing
            // a separate EditButton in the toolbar — matches Apple Contacts.app
            // where reordering is always-on while you're editing.
            editMode = .active
        } catch {
            editFetchErrorMessage = error.localizedDescription
        }
    }

    private func cancelEdit() {
        editModel = nil
        editMode = .inactive
    }

    private func performInlineSave() async {
        guard let model = editModel else { return }
        isSavingEdit = true
        defer { isSavingEdit = false }
        do {
            try await repository.saveContact(model.edited, for: id)
            editModel = nil
            editMode = .inactive
            // No reconcile here (6f): editing a contact's CONTACT fields is not a
            // GuessWho-sidecar write, so it must not stamp a guesswho:// URL — an
            // unstamped contact stays unstamped until the user adds notes/tags/
            // links/favorites, each of which mints via resolve-or-mint. Just
            // re-read the one record into the cache. loadContact(preferFresh:)
            // then re-reads the detail fields through the same fresh path so the
            // view shows post-save state immediately rather than waiting for a
            // nav-away-and-back.
            await loadContact(preferFresh: true)
        } catch {
            editSaveError = ContactEditModel.saveErrorCategory(error)
        }
    }

    private func performInlineDelete() async {
        isSavingEdit = true
        defer { isSavingEdit = false }
        do {
            guard try await repository.deleteContact(id: id) else { return }
            editModel = nil
            editMode = .inactive
            await loadContact()
            if contact == nil {
                dismiss()
            }
        } catch {
            let category = ContactEditModel.saveErrorCategory(error)
            // recordDoesNotExist means the contact is already gone —
            // exactly what the user asked for. Treat as success.
            if category == .recordDoesNotExist {
                editModel = nil
                editMode = .inactive
                repository.removeContact(id: id)
                await loadContact()
                if contact == nil {
                    dismiss()
                }
            } else {
                editDeleteError = category
            }
        }
    }

    // MARK: - Header (macOS inline)

    private func loadHeaderPhoto() async {
        guard let contact else {
            headerPhoto = nil
            return
        }

        let id = contact.contactID
        if let cached = photoLoader.cachedImage(for: id, kind: .fullSize) {
            headerPhoto = cached
            return
        }
        if let cachedThumbnail = photoLoader.cachedImage(for: id, kind: .thumbnail) {
            headerPhoto = cachedThumbnail
        } else {
            headerPhoto = nil
        }

        guard let image = await photoLoader.image(for: id, kind: .fullSize) else { return }
        guard self.contact?.contactID == id else { return }
        headerPhoto = image
    }

    /// Inline detail header used on macOS: large monogram circle, name,
    /// and a `job title · organization` subtitle. The nav-bar title is
    /// hidden in this configuration so the name only appears once.
    @ViewBuilder
    private func headerView(_ contact: Contact) -> some View {
        VStack(spacing: 12) {
            ZStack {
                if let headerPhoto {
                    Image(uiImage: headerPhoto)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                    Text(contact.initials)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text(contact.displayName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                let subtitle = headerSubtitle(contact)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func headerSubtitle(_ contact: Contact) -> String {
        let parts = [contact.jobTitle, contact.organizationName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    @ViewBuilder
    private func infoSection(_ contact: Contact) -> some View {
        // Mirror Apple's Contacts: one card with every populated field as
        // a label-above-value row, in roughly the same order Contacts uses.
        let rows = infoRows(for: contact)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    InfoRow(data: row)
                        .centeredRowContent()
                }
            }
        }
    }

    /// Named key/value sidecar fields (e.g. "LinkedIn About", "LinkedIn
    /// Location"). Read-only, label-above-value, one row per field. Hidden when
    /// the contact has none.
    @ViewBuilder
    private var sidecarFieldsSection: some View {
        let fields = fieldsStore?.fields ?? []
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.id) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.field)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Self.fieldDisplayValue(field))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .centeredRowContent()
                    .contextMenu {
                        Button {
                            fieldDraft = Self.fieldDisplayValue(field)
                            editingField = field
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button("Delete", role: .destructive) {
                            Task { await fieldsStore?.deleteField(field.id) }
                        }
                    }
                }
            }
        }
    }

    /// Render a sidecar field's value for display. `.note`-type fields hold a
    /// JSON string; fall back to a reasonable rendering for other shapes.
    private static func fieldDisplayValue(_ field: SidecarField) -> String {
        switch field.value {
        case .string(let s): return s
        case .bool(let b): return b ? "Yes" : "No"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .null: return ""
        case .array, .object: return ""
        }
    }

    /// "Recent Events": up to 10 EventKit events where this contact appears
    /// as an attendee, matched by any email on the card. Distinct from the
    /// user-curated linked events that surface in `activitySection`. Tapping
    /// a row pushes the event detail; the `eventKitID` hint lets the detail
    /// view's adopt-on-load path mint a sidecar on first open.
    @ViewBuilder
    private var recentEventsSection: some View {
        if !recentEvents.isEmpty {
            Section {
                ForEach(recentEvents, id: \.id) { event in
                    recentEventRow(event)
                        .centeredRowContent()
                }
            } header: {
                Text("Recent Events").centeredSectionHeader()
            }
        }
    }

    @ViewBuilder
    private func recentEventRow(_ event: Event) -> some View {
        Button {
            pushEventReference(
                EventReference(eventUUID: event.id.uuidString, eventKitID: event.eventKitID)
            )
        } label: {
            ActivityRowLayout(systemImage: "calendar") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title.isEmpty ? "(Untitled event)" : event.title)
                        .font(.body)
                        .foregroundStyle(.tint)
                    Text(event.startDate, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func referencedBySection(_ contact: Contact) -> some View {
        let backrefs = repository.contactsReferencing(contact: contact)
        if !backrefs.isEmpty {
            // Inbound relations read INVERSE: "Alice's mother is Bob"
            // becomes, on Bob's screen, a row showing Alice with the
            // descriptor "their mother" — i.e. Bob is Alice's mother.
            // Promoting the contact name to primary and demoting the
            // label to a "their <label>" caption keeps the direction
            // unambiguous.
            let rows = backrefs.map { entry in
                InfoRowData.backReference(
                    displayName: entry.contact.displayName,
                    descriptor: "their \(localizedLabel(entry.label))",
                    contactID: entry.contact.contactID
                )
            }
            Section {
                ForEach(rows) { row in
                    InfoRow(data: row)
                        .centeredRowContent()
                }
            } header: {
                Text("Referenced By").centeredSectionHeader()
            }
        }
    }

    private func infoRows(for contact: Contact) -> [InfoRowData] {
        var rows: [InfoRowData] = []

        // Skip the name parts (shown in the inline header) and the two fields
        // the header's subtitle already renders — job title and organization
        // (see `headerSubtitle`) — so they aren't duplicated. Department and
        // phonetic organization aren't in the header, so they stay.
        let workParts: [(String, String)] = [
            ("department", contact.departmentName),
            ("phonetic organization", contact.phoneticOrganizationName),
        ]
        for (label, value) in workParts where !value.isEmpty {
            rows.append(.text(label: label, value: value))
        }

        for item in contact.phoneNumbers {
            rows.append(.phone(label: localizedLabel(item.label), number: item.value))
        }
        for item in contact.emailAddresses {
            rows.append(.email(label: localizedLabel(item.label), address: item.value))
        }
        for item in contact.userVisibleURLAddresses {
            rows.append(.url(label: localizedLabel(item.label), urlString: item.value))
        }

        for item in contact.postalAddresses {
            rows.append(.address(label: localizedLabel(item.label), address: item.value))
        }

        if let bday = contact.birthday {
            rows.append(.date(label: "birthday", components: bday, formatted: formatDateComponents(bday)))
        }
        if let nonGreg = contact.nonGregorianBirthday {
            rows.append(.date(label: "non-gregorian birthday", components: nonGreg, formatted: formatDateComponents(nonGreg)))
        }
        for item in contact.dates {
            rows.append(.date(label: localizedLabel(item.label), components: item.value, formatted: formatDateComponents(item.value)))
        }

        for item in contact.socialProfiles {
            rows.append(.text(label: socialProfileLabel(item), value: socialProfileValue(item.value)))
        }
        for item in contact.instantMessageAddresses {
            rows.append(.text(label: instantMessageLabel(item), value: item.value.username))
        }
        let lookup = repository.lookupByDisplayName()
        let selfID = contact.contactID
        for item in contact.contactRelations {
            let key = item.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Compare by ContactID (effective GuessWho identity), not raw
            // localID, so a relation pointing at this very contact is excluded
            // by stable identity rather than the transient identifier. Mint the
            // match's ContactID once (it re-parses the GuessWho URL) and reuse it.
            if !key.isEmpty, let match = lookup[key],
               case let matchID = match.contactID, matchID != selfID {
                rows.append(.contactLink(
                    label: localizedLabel(item.label),
                    displayName: match.displayName,
                    contactID: matchID
                ))
            } else {
                rows.append(.text(label: localizedLabel(item.label), value: item.value.name))
            }
        }

        return rows
    }

    @ViewBuilder
    private func debugSection(_ contact: Contact) -> some View {
        let rows = debugRows(for: contact)
        Section {
            ForEach(rows) { row in
                InfoRow(data: row)
                    .centeredRowContent()
            }
        } header: {
            Text("Debug").centeredSectionHeader()
        }
    }

    private func debugRows(for contact: Contact) -> [InfoRowData] {
        var rows: [InfoRowData] = []
        let debugInfo = repository.identityDebugInfo(for: contact)

        rows.append(.text(label: "localID", value: debugInfo.contactsIdentifier, monospaced: true))
        rows.append(.text(label: "contact type", value: contact.contactType.rawValue))
        rows.append(.text(label: "image available", value: contact.imageDataAvailable ? "yes" : "no"))

        if let uuid = debugInfo.guessWhoID {
            rows.append(.text(label: "guesswho uuid", value: uuid, monospaced: true))
        } else if let reason = sidecarUnavailableReason {
            rows.append(.text(label: "guesswho uuid", value: "none — \(reason)"))
        } else {
            rows.append(.text(label: "guesswho uuid", value: "none"))
        }

        for item in debugInfo.guessWhoURLs {
            rows.append(.text(label: "guesswho url (\(localizedLabel(item.label)))", value: item.value, monospaced: true))
        }

        // The reconcile-outcome and raw-sidecar-envelope debug readouts were
        // dropped in Stage 6: reconcile is now a package-internal side effect
        // the view no longer drives (so there's no app-side outcome to show),
        // and surfacing it would mean retaining new per-contact package state
        // purely for a debug row. The package-vended identity diagnostics above
        // remain under the debug carve-out.

        return rows
    }

    // MARK: - Activity (merged notes + connections + linked events)

    @ViewBuilder
    private var activitySection: some View {
        let items = activityItems
        if !items.isEmpty || showingNewNoteEditor {
            Section {
                ForEach(items) { item in
                    activityRow(item)
                        .centeredRowContent()
                }
                .onDelete { offsets in
                    let targets = offsets.map { items[$0] }
                    for target in targets { deleteActivityItem(target) }
                }

                if showingNewNoteEditor {
                    TextField("Add a note", text: $newNoteText, axis: .vertical)
                        .focused($noteFocus, equals: .newNote)
                        .centeredRowContent()
                }
            } header: {
                Text("Activity").centeredSectionHeader()
            }
        }
    }

    @ViewBuilder
    private var activityFooter: some View {
        HStack(spacing: 0) {
            activityFooterButton(
                title: "Add Note",
                systemImage: "note.text",
                action: { showNewNoteEditor() }
            )
            .disabled(notesStore == nil)

            Divider()

            activityFooterButton(
                title: "Link Contact",
                systemImage: "person.line.dotted.person",
                action: { showingAddLinkSheet = true }
            )
            // No UUID gate: the link WRITE reconciles + mints the GuessWho UUID
            // internally, so a never-touched contact can be linked. `linksStore`
            // is built for every loaded contact, so this only disables until the
            // first load finishes.
            .disabled(linksStore == nil)
            .sheet(isPresented: $showingAddLinkSheet) {
                if let linksStore {
                    // The picker hands back the far endpoint's ContactID; the
                    // store's async addLink resolves-or-mints BOTH endpoints.
                    // The store is @Observable, so adding the link re-renders
                    // the connection rows; each row asks the package to resolve
                    // the other endpoint.
                    AddLinkSheet(currentContactID: id) { otherID, note in
                        Task { await linksStore.addLink(to: otherID, note: note) }
                    }
                }
            }

            Divider()

            activityFooterButton(
                title: "Link Event",
                systemImage: "calendar.badge.plus",
                action: { showingEventPicker = true }
            )
            // No UUID gate: addEventLink reconciles + mints internally.
            .sheet(isPresented: $showingEventPicker) {
                EventLinkSheet(mode: .link(onLinked: { eventUUID, note in
                    Task { await addEventLink(eventUUID: eventUUID, note: note) }
                }))
            }
        }
        // Zero the row insets so the footer content view spans the full cell,
        // then clamp/center that content to the same column as every other row.
        .listRowInsets(EdgeInsets())
        .centeredRowContent()
    }

    @ViewBuilder
    private func activityFooterButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func activityRow(_ item: ActivityItem) -> some View {
        switch item {
        case .note(let note):
            noteRow(note)
        case .connection(let link):
            connectionRow(link)
        case .event(let link):
            linkedEventRow(link)
        }
    }

    @ViewBuilder
    private func noteRow(_ note: ContactNote) -> some View {
        if editingNoteID == note.id {
            ActivityRowLayout(systemImage: "text.rectangle") {
                TextField("", text: $draftBody, axis: .vertical)
                    .focused($noteFocus, equals: .noteRow(note.id))
            }
        } else {
            Button {
                beginEdit(note)
            } label: {
                ActivityRowLayout(systemImage: "text.rectangle") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.body)
                        Text(note.createdAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    beginEdit(note)
                } label: {
                    Label("Edit Note", systemImage: "pencil")
                }
                Button("Delete", role: .destructive) {
                    deleteNote(note.id)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ link: ContactLink) -> some View {
        if let contact, link.direction(for: contact.contactID) != nil {
            LinkRow(
                link: link,
                otherContact: repository.linkedContact(of: link, for: loadedContactID ?? id),
                isEditing: editingLinkID == link.id,
                draftNote: $draftLinkNote,
                noteFocus: $noteFocus,
                focusValue: .linkRow(link.id),
                onBeginEdit: { beginLinkEdit(link) },
                onCommit: { commitLinkEditIfChanged() },
                onCancel: { cancelLinkEdit() },
                onDelete: { deleteLink(link.id) }
            )
        }
    }

    @ViewBuilder
    private func linkedEventRow(_ link: ContactLink) -> some View {
        // Resolve the link's EVENT endpoint through the repository so the app
        // never builds a `.contact` SidecarKey to walk the link. nil only for a
        // malformed/unreconciled link; the event lookup then misses → "(Unknown
        // event)".
        let eventUUID = repository.eventEndpointUUID(of: link, for: loadedContactID ?? id)
        let event = eventUUID.flatMap { service.event(uuid: $0) }
        let isEditing = editingLinkID == link.id
        ActivityRowLayout(systemImage: "calendar") {
            VStack(alignment: .leading, spacing: 4) {
                if let event, let eventUUID {
                    Button {
                        pushEventReference(EventReference(eventUUID: eventUUID))
                    } label: {
                        Text(event.title.isEmpty ? "(Untitled event)" : event.title)
                            .font(.body)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("(Unknown event)")
                        .foregroundStyle(.secondary)
                }

                if isEditing {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("", text: $draftLinkNote, axis: .vertical)
                            .focused($noteFocus, equals: .linkRow(link.id))
                        HStack(spacing: 12) {
                            Spacer()
                            Button("Cancel", role: .cancel) { cancelLinkEdit() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Done") { commitLinkEditIfChanged() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                } else {
                    Button {
                        beginLinkEdit(link)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if !link.note.isEmpty {
                                Text(link.note)
                            }
                            if let event {
                                Text(event.startDate, format: .dateTime.month(.abbreviated).day().year())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contextMenu {
            Button {
                beginLinkEdit(link)
            } label: {
                Label("Edit Note", systemImage: "pencil")
            }
            Button("Delete", role: .destructive) {
                removeEventLink(link.id)
            }
        }
    }

    private func deleteActivityItem(_ item: ActivityItem) {
        switch item {
        case .note(let n): deleteNote(n.id)
        case .connection(let l): deleteLink(l.id)
        case .event(let l): removeEventLink(l.id)
        }
    }

    private func showNewNoteEditor() {
        guard notesStore != nil else { return }
        showingNewNoteEditor = true
        noteFocus = .newNote
    }

    /// The ContactID derived from the LOADED contact, carrying its current
    /// `guessWhoID` (which the nav `id` lacks after a first-write mint).
    /// The repository's sidecar reads (`eventLinks(for:)`) key on the passed
    /// ContactID's `guessWhoID`, so reads must use THIS, not the stale nav `id`.
    /// nil only before the first load resolves a contact.
    private var loadedContactID: ContactID? {
        guard let contact else { return nil }
        return contact.contactID
    }

    private var isContactFavorited: Bool {
        // Read through the @Observable app-side favorites cache so the star
        // reacts to a toggle. The cache asks package `Favorite.matches(_:)` to
        // compare the opaque ContactID to the stored GuessWho UUID.
        guard let id = loadedContactID else { return false }
        return favoritesStore.isFavorite(id)
    }

    private func toggleFavorite() async {
        // Route through the repository, which resolves-or-mints the GuessWho UUID
        // first (favoriting a never-touched contact reconciles + mints,
        // transparent here) then toggles the CONTACT favorite and pokes its
        // cache. We then reload the contact so its `ContactID` carries the
        // just-minted `guessWhoID`, and refresh the @Observable app-side
        // favorites cache so the star + the favorites list update (the
        // repository writes the same on-disk file the app-side store mirrors,
        // but doesn't drive its observable state).
        do {
            _ = try await repository.toggleFavorite(id)
        } catch {
            // Sidecar storage unavailable or write failed. Record it to the
            // service's error state (the same surface `addEventLink` uses) rather
            // than swallowing it silently; the reload + refresh below still show
            // what actually landed on disk.
            service.recordError("toggle favorite failed: \(error.localizedDescription)")
        }
        await loadContact()
        favoritesStore.reload()
    }

    private func reloadEventLinks() {
        // The contact↔event link READS go through the repository, keyed on the
        // LOADED contact's ContactID (which carries the current guessWhoID; the
        // nav `id` lacks it after a first-write mint). Empty for an unreconciled
        // contact — it has no links yet.
        let linkID = loadedContactID ?? id
        eventLinks = repository.eventLinks(for: linkID)
        // The EventKit cache refresh stays on SyncService (an event-surface
        // concern, out of Stage 6 scope). The repository resolves the linked
        // event UUIDs (so the app builds no `.contact` SidecarKey to walk the
        // links); SyncService then debounces-and-refreshes each. Option C
        // cache-refresh trigger (b): fire on initial contact load only.
        service.refreshLinkedEvents(eventUUIDs: repository.linkedEventUUIDs(for: linkID))
    }

    private func addEventLink(eventUUID: String, note: String) async {
        do {
            // The write resolves-or-mints the CONTACT endpoint's GuessWho UUID
            // internally, so a never-touched contact can link an event.
            _ = try await repository.addEventLink(for: id, eventUUID: eventUUID, note: note)
        } catch {
            service.recordError("add contact-event link failed: \(error.localizedDescription)")
        }
        // A first link may have minted the UUID, re-keying the cache. Re-resolve
        // the loaded contact off the reconcile-stable `contact(id:)` so
        // `loadedContactID` carries the new guessWhoID, then re-read event links
        // off it and re-key the notes/links stores onto the minted identity. We
        // do this targeted re-read (not a full loadContact) to avoid refiring
        // refreshLinkedEvents — see E4 / C-REFRESH-FANOUT; the freshly-added
        // event refreshes when the user opens its detail view.
        contact = repository.contact(id: id)
        if let contact { rebuildSidecarStores(for: contact) }
        eventLinks = repository.eventLinks(for: loadedContactID ?? id)
    }

    private func removeEventLink(_ id: UUID) {
        // Clear edit state first: setLinkNote on a soft-deleted link
        // undeletes it (§13 link API), so a pending edit must NOT be
        // committed after the delete lands.
        if editingLinkID == id {
            editingLinkID = nil
            draftLinkNote = ""
            editLinkStartSnapshot = ""
            if case .linkRow(let focused) = noteFocus, focused == id {
                noteFocus = nil
            }
        }
        do {
            try repository.removeLink(id: id)
        } catch {
            service.recordError("remove link failed: \(error.localizedDescription)")
        }
        // Do NOT refire refreshLinkedEvents — see E4 / C-REFRESH-FANOUT. The
        // contact already has a UUID (it had event links to remove), so reading
        // off `loadedContactID` resolves; `self.id` is the fallback.
        eventLinks = repository.eventLinks(for: loadedContactID ?? self.id)
    }

    // MARK: - Loading & reconcile

    private var sidecarUnavailableReason: String? {
        if case .unavailable(let reason) = service.sidecarLocation { return reason }
        return nil
    }

    private func loadContact(preferFresh: Bool = false) async {
        // Resolve the live contact off the view's captured `ContactID`. Since
        // 6b2 made `contact(id:)` reconcile-stable (it chases the guessWhoID
        // pointer when present, else falls back to the token's always-present
        // `localID`), the captured `id` keeps resolving even after a first-write
        // reconcile re-keys the contact's effective identity — no separately
        // threaded `localID` needed.
        let loaded: Contact?
        if preferFresh, let fresh = try? await repository.editableContact(id: id) {
            // Post-save read: route through unifiedContact(withIdentifier:)
            // which is more consistent than the enumerate path the
            // repository cache uses on Catalyst right after a write.
            loaded = fresh
        } else {
            loaded = repository.contact(id: id)
        }
        contact = loaded
        if let loaded {
            rebuildSidecarStores(for: loaded)
            reloadEventLinks()
            await reloadRecentEvents(for: loaded)
        } else {
            // Contact disappeared from the store (e.g. deleted via the
            // edit sheet). Tear down sidecar-bound state so nothing keeps
            // reading/writing a dead identity while the view animates away.
            // Safe to nil regardless of whether the caller is about to
            // dismiss — a re-load would reconstruct them.
            notesStore = nil
            fieldsStore = nil
            linksStore = nil
            eventLinks = []
            recentEvents = []
        }
    }

    /// (Re)build the notes/links stores keyed on the ContactID derived from the
    /// LOADED contact — NOT the nav `id`, whose `guessWhoID` is still nil after
    /// a first-write mint: `repository.notes(for:)` / `links(for:)` read
    /// the `guessWhoID` directly off the passed ContactID. Rebuild a store when
    /// that identity changes — a first-write/Case-A mint stamps a fresh UUID, and
    /// a Case-D reconcile picks a winner UUID and deletes the loser's sidecar, so
    /// a store bound to the old identity would read/write a dead file. Stores are
    /// built for EVERY contact (even unreconciled): reads return empty until a
    /// write reconciles + mints, so notes/links can be added to a never-touched
    /// contact.
    private func rebuildSidecarStores(for loaded: Contact) {
        let loadedID = loaded.contactID
        if notesStore?.id != loadedID {
            notesStore = NotesStore(repository: repository, id: loadedID)
        } else {
            notesStore?.reload()
        }
        if fieldsStore?.id != loadedID {
            fieldsStore = FieldsStore(repository: repository, id: loadedID)
        } else {
            fieldsStore?.reload()
        }
        if linksStore?.id != loadedID {
            linksStore = ContactLinksStore(repository: repository, id: loadedID)
        } else {
            linksStore?.reload()
        }
    }

    /// Fetch up to 10 EventKit events where this contact appears as an
    /// attendee (matched by any email on the card). Runs on a background
    /// queue inside `SyncService.recentEvents`; the awaited result resumes
    /// back on the main actor. No-op when the contact has no emails.
    private func reloadRecentEvents(for contact: Contact) async {
        let myLoadID = UUID()
        recentEventsLoadID = myLoadID
        let emails = Set(contact.emailAddresses.map { $0.value })
        guard !emails.isEmpty else {
            // Synchronous from the token bump above — no suspension, no race.
            recentEvents = []
            return
        }
        let fetched = await service.recentEvents(forEmails: emails, limit: 10)
        // Bail if a newer reload started while this fetch was in flight —
        // covers navigation away, contact-emails edit, and rapid reloads on
        // the same localID. Stronger than a localID compare, which can't
        // distinguish two same-localID reloads in quick succession.
        guard recentEventsLoadID == myLoadID else { return }
        recentEvents = fetched
    }

    // MARK: - Notes

    private func beginEdit(_ note: ContactNote) {
        // Tapping a different row mid-edit commits the prior one first.
        if let editingNoteID, editingNoteID != note.id {
            commitRowEditIfChanged()
        }
        if editingLinkID != nil {
            commitLinkEditIfChanged()
        }
        editingNoteID = note.id
        draftBody = note.body
        editStartSnapshot = note.body
        noteFocus = .noteRow(note.id)
    }

    private func deleteNote(_ id: UUID) {
        if editingNoteID == id {
            editingNoteID = nil
            draftBody = ""
            editStartSnapshot = ""
            if case .noteRow(let focused) = noteFocus, focused == id {
                noteFocus = nil
            }
        }
        if let notesStore {
            Task { await notesStore.deleteNote(id) }
        }
    }

    private func commitActiveEdit() {
        switch noteFocus {
        case .newNote:
            commitNewNote()
        case .noteRow:
            commitRowEditIfChanged()
        case .linkRow:
            commitLinkEditIfChanged()
        case .none:
            break
        }
        noteFocus = nil
    }

    private func commitNewNote() {
        let body = newNoteText
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let notesStore {
            Task { await notesStore.addNote(body: body) }
        }
        newNoteText = ""
        showingNewNoteEditor = false
    }

    private func commitRowEditIfChanged() {
        guard let id = editingNoteID else { return }
        let proposed = draftBody
        let snapshot = editStartSnapshot
        editingNoteID = nil
        draftBody = ""
        editStartSnapshot = ""
        if proposed == snapshot { return }
        if let notesStore {
            Task { await notesStore.editNote(id, newBody: proposed) }
        }
    }

    // MARK: - Contact-contact links (connections)

    private func beginLinkEdit(_ link: ContactLink) {
        if editingNoteID != nil {
            commitRowEditIfChanged()
        }
        if let editingLinkID, editingLinkID != link.id {
            commitLinkEditIfChanged()
        }
        editingLinkID = link.id
        draftLinkNote = link.note
        editLinkStartSnapshot = link.note
        noteFocus = .linkRow(link.id)
    }

    private func commitLinkEditIfChanged() {
        guard let id = editingLinkID else { return }
        let proposed = draftLinkNote
        let snapshot = editLinkStartSnapshot
        editingLinkID = nil
        draftLinkNote = ""
        editLinkStartSnapshot = ""
        if case .linkRow(let focused) = noteFocus, focused == id {
            noteFocus = nil
        }
        if proposed == snapshot { return }
        if linksStore?.links.contains(where: { $0.id == id }) == true {
            linksStore?.setNote(id: id, note: proposed)
        } else if eventLinks.contains(where: { $0.id == id }) {
            do {
                // A contact↔event link's note edit goes through the shared
                // repository link-note write (keyed on the link's own UUID, no
                // contact resolve needed), then re-reads the event links off the
                // loaded contact's ContactID.
                try repository.setLinkNote(id: id, note: proposed)
                eventLinks = repository.eventLinks(for: loadedContactID ?? self.id)
            } catch {
                service.recordError("set event-link note failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelLinkEdit() {
        editingLinkID = nil
        draftLinkNote = ""
        editLinkStartSnapshot = ""
        if case .linkRow = noteFocus {
            noteFocus = nil
        }
    }

    private func deleteLink(_ id: UUID) {
        // Clear edit state first: setLinkNote on a soft-deleted link
        // undeletes it (§13 link API), so a pending edit must NOT be
        // committed after the delete lands.
        if editingLinkID == id {
            editingLinkID = nil
            draftLinkNote = ""
            editLinkStartSnapshot = ""
            if case .linkRow(let focused) = noteFocus, focused == id {
                noteFocus = nil
            }
        }
        linksStore?.remove(id: id)
    }

    // MARK: - Formatting

    private func localizedLabel(_ raw: String) -> String {
        if raw.isEmpty { return "other" }
        return CNLabeledValue<NSString>.localizedString(forLabel: raw)
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
}

private struct InfoRowData: Identifiable {
    enum Kind {
        case text(value: String, monospaced: Bool, valueColor: Color?)
        case phone(number: String)
        case email(address: String)
        case url(urlString: String)
        case address(PostalAddress)
        case date(components: DateComponents, formatted: String)
        case contactLink(displayName: String, contactID: ContactID)
        case backReference(displayName: String, descriptor: String, contactID: ContactID)
    }

    let id = UUID()
    let label: String
    let kind: Kind

    static func text(label: String, value: String, monospaced: Bool = false, valueColor: Color? = nil) -> InfoRowData {
        InfoRowData(label: label, kind: .text(value: value, monospaced: monospaced, valueColor: valueColor))
    }
    static func phone(label: String, number: String) -> InfoRowData {
        InfoRowData(label: label, kind: .phone(number: number))
    }
    static func email(label: String, address: String) -> InfoRowData {
        InfoRowData(label: label, kind: .email(address: address))
    }
    static func url(label: String, urlString: String) -> InfoRowData {
        InfoRowData(label: label, kind: .url(urlString: urlString))
    }
    static func address(label: String, address: PostalAddress) -> InfoRowData {
        InfoRowData(label: label, kind: .address(address))
    }
    static func date(label: String, components: DateComponents, formatted: String) -> InfoRowData {
        InfoRowData(label: label, kind: .date(components: components, formatted: formatted))
    }
    static func contactLink(label: String, displayName: String, contactID: ContactID) -> InfoRowData {
        InfoRowData(label: label, kind: .contactLink(displayName: displayName, contactID: contactID))
    }
    static func backReference(displayName: String, descriptor: String, contactID: ContactID) -> InfoRowData {
        // No top-line label here — the back-ref row's primary text is
        // the contact name, with the descriptor as a small caption.
        InfoRowData(label: "", kind: .backReference(displayName: displayName, descriptor: descriptor, contactID: contactID))
    }
}

private struct InfoRow: View {
    let data: InfoRowData
    // Bridge to the outer UIKit nav controller (iPhone shell) for
    // contact-link and back-reference rows — pushes a fresh
    // ContactDetailView via SceneDelegate. Defaults to a no-op closure
    // (see `ReferenceNavigation.swift`).
    @Environment(\.pushContactReference) private var pushContactReference

    var body: some View {
        switch data.kind {
        case .text(let value, let monospaced, let valueColor):
            labeledValue(label: data.label, value: value, monospaced: monospaced, valueColor: valueColor)
        case .phone(let number):
            tappableRow(label: data.label, value: number, url: phoneURL(number))
        case .email(let address):
            tappableRow(label: data.label, value: address, url: URL(string: "mailto:\(address)"))
        case .url(let urlString):
            tappableRow(label: data.label, value: urlString, url: URL(string: urlString))
        case .address(let address):
            AddressRow(label: data.label, address: address)
        case .date(let components, let formatted):
            tappableRow(label: data.label, value: formatted, url: calendarURL(for: components))
        case .contactLink(let displayName, let contactID):
            contactLinkRow(label: data.label, displayName: displayName, contactID: contactID)
        case .backReference(let displayName, let descriptor, let contactID):
            backReferenceRow(displayName: displayName, descriptor: descriptor, contactID: contactID)
        }
    }

    @ViewBuilder
    private func backReferenceRow(displayName: String, descriptor: String, contactID: ContactID) -> some View {
        // Inverse-relation row: contact name is primary tinted (the
        // tappable target) and the descriptor reads "their <label>" in
        // small caption so the relationship direction is unambiguous.
        Button {
            pushContactReference(ContactReference(id: contactID))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .foregroundStyle(.tint)
                Text(descriptor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contactLinkRow(label: String, displayName: String, contactID: ContactID) -> some View {
        // Match the tappable-row visual: label above, tinted value, whole
        // row tappable. Push goes through the env-injected closure so
        // SwiftUI rows pushed onto a UIKit nav stack still navigate.
        Button {
            pushContactReference(ContactReference(id: contactID))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func labeledValue(label: String, value: String, monospaced: Bool, valueColor: Color?) -> some View {
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

    @ViewBuilder
    private func tappableRow(label: String, value: String, url: URL?) -> some View {
        if let url {
            // Apple's Contacts colors the value in tint and the whole row
            // is the hit target — Link wrapping the VStack does both.
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
        } else {
            labeledValue(label: label, value: value, monospaced: false, valueColor: nil)
        }
    }

    private func phoneURL(_ raw: String) -> URL? {
        // tel: requires digits only (plus '+'); strip everything else.
        let allowed = Set("+0123456789")
        let cleaned = raw.filter { allowed.contains($0) }
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "tel:\(cleaned)")
    }

    private func calendarURL(for components: DateComponents) -> URL? {
        // Calendar's calshow: scheme takes seconds since 2001-01-01.
        // Birthdays often lack a year; in that case land Calendar on
        // this year's occurrence so the user sees the next/most recent
        // one rather than year 1.
        var resolved = components
        if resolved.year == nil {
            resolved.year = Calendar(identifier: .gregorian).component(.year, from: Date())
        }
        if resolved.hour == nil { resolved.hour = 12 }
        if resolved.minute == nil { resolved.minute = 0 }
        guard let date = Calendar(identifier: .gregorian).date(from: resolved) else {
            return URL(string: "calshow:")
        }
        return URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))")
    }
}

private struct AddressRow: View {
    let label: String
    let address: PostalAddress

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var didStartGeocode = false

    var body: some View {
        Button {
            openInMaps()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatted)
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                mapPreview
            }
        }
        .buttonStyle(.plain)
        .task {
            guard !didStartGeocode else { return }
            didStartGeocode = true
            await geocode()
        }
    }

    @ViewBuilder
    private var mapPreview: some View {
        if let coordinate {
            // Static, non-interactive preview — taps fall through to the
            // surrounding Button so the whole row opens Maps as one unit.
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Marker("", coordinate: coordinate)
                    .tint(.red)
            }
            .allowsHitTesting(false)
            .frame(width: 96, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            // Reserve the same footprint so the row doesn't reflow when
            // the geocode resolves.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 96, height: 72)
        }
    }

    private var formatted: String {
        let cn = mutablePostalAddress()
        return CNPostalAddressFormatter.string(from: cn, style: .mailingAddress)
    }

    private func mutablePostalAddress() -> CNMutablePostalAddress {
        let cn = CNMutablePostalAddress()
        cn.street = address.street
        cn.subLocality = address.subLocality
        cn.city = address.city
        cn.subAdministrativeArea = address.subAdministrativeArea
        cn.state = address.state
        cn.postalCode = address.postalCode
        cn.country = address.country
        cn.isoCountryCode = address.isoCountryCode
        return cn
    }

    private func geocode() async {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodePostalAddress(mutablePostalAddress())
            await MainActor.run {
                self.coordinate = placemarks.first?.location?.coordinate
            }
        } catch {
            // Leave the placeholder; the row still functions, tap still
            // launches Maps which will do its own resolution.
        }
    }

    private func openInMaps() {
        let placemark: MKPlacemark
        if let coordinate {
            placemark = MKPlacemark(coordinate: coordinate, postalAddress: mutablePostalAddress())
        } else {
            // Maps accepts a placemark with no coordinate and resolves
            // it from the address fields.
            placemark = MKPlacemark(coordinate: kCLLocationCoordinate2DInvalid, postalAddress: mutablePostalAddress())
        }
        let item = MKMapItem(placemark: placemark)
        item.name = formatted
        item.openInMaps(launchOptions: nil)
    }
}

/// Presents an editing alert for a sidecar field. Shown when `field` is non-nil;
/// `draft` holds the working text. Save invokes `onSave(field, draft)`.
private struct EditFieldAlert: ViewModifier {
    @Binding var field: SidecarField?
    @Binding var draft: String
    let onSave: (SidecarField, String) -> Void

    func body(content: Content) -> some View {
        let isPresented = Binding(
            get: { field != nil },
            set: { if !$0 { field = nil } }
        )
        content.alert(field?.field ?? "Edit", isPresented: isPresented) {
            TextField("Value", text: $draft)
            Button("Cancel", role: .cancel) { field = nil }
            Button("Save") {
                if let f = field { onSave(f, draft) }
                field = nil
            }
        }
    }
}
