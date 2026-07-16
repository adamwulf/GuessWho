import SwiftUI
import Contacts
import MapKit
import PhotosUI
import UniformTypeIdentifiers
import GuessWhoSync
import GuessWhoLogging

struct ContactDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(ContactsRepository.self) private var repository
    @Environment(ContactPhotoLoader.self) private var photoLoader
    @Environment(FavoritesListStore.self) private var favoritesStore
    @Environment(\.dismiss) private var dismiss
    // Set by SceneDelegate when this view is pushed onto an iPhone UIKit nav
    // stack. Defaults to a no-op closure (see `ReferenceNavigation.swift`),
    // which is also what Catalyst gets today.
    @Environment(\.pushContactReference) private var pushContactReference
    @Environment(\.pushEventReference) private var pushEventReference
    @Environment(\.pushDepartmentReference) private var pushDepartmentReference
    @Environment(\.pushGroupReference) private var pushGroupReference

    /// The view's identity is the opaque, package-vended `ContactID` the scene
    /// delegate hands in — NEVER a raw `localID`. The view resolves it to a
    /// `Contact` via `repository.contact(id:)`, which is reconcile-stable: it
    /// falls back to the `ContactID`'s always-present `localID` when the captured
    /// token's `guessWhoID` is still nil after a first-write reconcile, so the
    /// view re-loads off this same captured `id` with no separately-threaded
    /// `localID` token. The handful of contact-LIFECYCLE calls that genuinely
    /// need a `CNContact.identifier` (edit/save/delete/fetch) read it from the
    /// loaded `Contact` at the call site.
    let id: ContactID

    /// When true, the view flips straight into inline edit after the first
    /// successful load — the "+" add-contact and LinkedIn-import flows create
    /// the record first, then open it here already editing, so brand-new and
    /// existing contacts share one form (no separate new-contact sheet).
    var startsInEditMode: Bool = false

    /// The full selection when this card is the front sheet of a stacked
    /// multi-contact detail. An empty array is the normal single-contact path.
    /// Multi-selection keeps this card's content while adapting its toolbar:
    /// editing one arbitrary member is unavailable and favorite mutations apply
    /// to the complete selection.
    var selectedContactIDs: [ContactID] = []

    @State private var contact: Contact?
    @State private var headerPhoto: UIImage?
    // Drives the fullscreen, zoomable photo viewer. Set when the user taps the
    // header photo (only possible when a real photo is loaded) so the cover
    // shows the same image the header does. Boxed as Identifiable because
    // `.fullScreenCover(item:)` requires it and UIImage isn't.
    @State private var fullscreenPhoto: FullscreenPhoto?
    // Edit-mode photo change. Presents the system PhotosPicker on iOS/iPadOS, or
    // a native macOS file Open panel on Catalyst — driven in-process by the
    // AppKitBridge bundle, NOT a document-picker sheet (see `PhotoChangeModifier`)
    // — with no intermediate Choose/Remove menu. `photoPickerItem` binds the
    // iOS/iPadOS PhotosPicker selection so the picked item can be written.
    @State private var presentingPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var photoSaveError: String?
    @State private var notesStore: NotesStore?
    @State private var fieldsStore: FieldsStore?
    @State private var linksStore: ContactLinksStore?
    @State private var eventLinks: [ContactLink] = []
    @State private var showingEventPicker = false
    // EventKit events matched to this contact — the contact appears as an
    // attendee (matched by any email on the card) or the event's location text
    // contains one of the contact's street lines. Loaded async via SyncService
    // on each contact load — separate from `eventLinks`, which are user-curated
    // contact↔event links.
    @State private var recentEvents: [Event] = []
    // Token bumped at the start of every `reloadRecentEvents` call. The async
    // load captures it and bails on assignment when it no longer matches, so a
    // stale in-flight fetch (after navigation, a contact-emails edit, or rapid
    // reloads) can't overwrite the freshest result. Stronger than a localID
    // check, which can't tell two same-localID reloads apart.
    @State private var recentEventsLoadID: UUID = UUID()
    // Imported guides whose places' addresses contain one of this contact's
    // structured street lines. Rendered directly under the address rows, in the
    // same info section. Loaded async via SyncService on each contact load,
    // guarded by its own load token like `recentEvents`.
    @State private var addressGuides: [GuideAddressMatcher.Match] = []
    @State private var addressGuidesLoadID: UUID = UUID()
    // Contacts.app groups this record belongs to (people AND organizations — a
    // group holds either). Loaded async via the repository on each contact load.
    @State private var memberGroups: [ContactGroup] = []
    // Token bumped at the start of every `reloadGroups` call so a stale in-flight
    // membership scan can't overwrite the freshest result, exactly like
    // `recentEventsLoadID` guards the recent-events fetch.
    @State private var memberGroupsLoadID: UUID = UUID()
    @State private var showingAddLinkSheet = false
    @State private var showingAddOrgLinkSheet = false
    @State private var showingNewNoteEditor = false
    @State private var editFetchErrorMessage: String?

    // Inline contact-edit state. Non-nil `editModel` means the view has flipped
    // into in-place editing (no sheet). Seeded from a fresh package-owned edit
    // fetch when the user taps Edit; nilled out on Cancel/Save.
    @State private var editModel: ContactEditModel?
    @State private var isSavingEdit = false
    @State private var editSaveError: ContactEditModel.SaveErrorCategory?
    @State private var editDeleteError: ContactEditModel.SaveErrorCategory?
    // Owned edit-mode for the editing list. Without an owned binding, EditButton
    // drives an unscoped \.editMode that stays .active after the user exits
    // contact-edit, leaking drag-handle/delete-circle affordances into the
    // read-only activity list. Reset to .inactive on every exit.
    @State private var editMode: EditMode = .inactive
    @State private var showDeleteConfirm = false

    // Focus identity covers the bottom new-note editor and any row being edited.
    // Hoisted here so one nav-bar checkmark can commit whichever edit is active
    // and dismiss the keyboard.
    enum NoteFocus: Hashable {
        case newNote
        case noteRow(UUID)
        case linkRow(UUID)
    }
    @FocusState private var noteFocus: NoteFocus?
    @State private var newNoteText: String = ""
    // The new note's user-picked date. nil = untouched, meaning "now" at
    // commit time (not at editor-open time), so a note typed slowly still
    // stamps the actual save moment unless the user picked a date.
    @State private var newNoteDate: Date?
    @State private var editingNoteID: UUID?
    @State private var draftBody: String = ""
    // The edited note's working date, seeded from the note's createdAt.
    @State private var draftNoteDate: Date = .now
    // Sidecar-field edit state: the field being edited (presented in an alert)
    // and its working text.
    @State private var editingField: SidecarField?
    @State private var fieldDraft: String = ""
    // Body captured at edit-start: commit is a no-op only when the draft is
    // unchanged from THIS snapshot — never the current on-disk value. Matters
    // when a reconcile lands mid-edit and rewrites the on-disk body.
    @State private var editStartSnapshot: String = ""
    // Date captured at edit-start; commit re-stamps the note's date only when
    // the draft date moved off THIS snapshot.
    @State private var editStartDateSnapshot: Date = .now

    @AppStorage(AppSettings.Key.debugModeEnabled) private var debugModeEnabled = AppSettings.Default.debugModeEnabled

    // Which info field groups (phones/emails/urls) have had their "old"-labeled
    // rows revealed via the per-group "more…" disclosure. Empty = all collapsed.
    @State private var expandedFieldGroups: Set<InfoRowData.FieldGroup> = []

    // Contact-link edit state.
    @State private var editingLinkID: UUID?
    @State private var draftLinkNote: String = ""
    @State private var editLinkStartSnapshot: String = ""

    private var isEditingAnything: Bool {
        // Keyboard focus alone isn't enough: interacting with a note editor's
        // date picker drops text-field focus while the editor is still open,
        // and the Done checkmark must stay reachable to commit it.
        noteFocus != nil || showingNewNoteEditor || editingNoteID != nil
    }

    private var isEditingContact: Bool {
        editModel != nil
    }

    private var noteItems: [ContactNote] {
        (notesStore?.notes ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Contact↔contact links whose OTHER endpoint is a person, sorted ASC.
    private var linkedPeople: [ContactLink] {
        connectionLinks(where: .person)
    }

    /// Contact↔contact links whose OTHER endpoint is an organization, ASC.
    private var linkedOrganizations: [ContactLink] {
        connectionLinks(where: .organization)
    }

    private var linkedEventItems: [ContactLink] {
        eventLinks.sorted { $0.createdAt < $1.createdAt }
    }

    /// The "Linked Events" link pointing at `event`, if any. Drives the
    /// recent-event long-press menu: a match means the row is already linked,
    /// so the menu offers "Unlink Event" (removing this link) instead of
    /// "Link Event".
    ///
    /// Recent-event rows live in the EventKit id-space: their `id` is the
    /// synthetic `Event.stableID(forEventKitID:)`, while a link's event
    /// endpoint stores the real sidecar UUID — the two never compare equal.
    /// Match on the linked sidecar event's `eventKitID` instead, keeping the
    /// direct UUID comparison only for sidecar-only (manual) events.
    private func eventLink(for event: Event) -> ContactLink? {
        eventLinks.first { link in
            guard let endpointUUID = repository.eventEndpointUUID(
                of: link, for: loadedContactID ?? id
            ) else { return false }
            if endpointUUID == event.id.uuidString { return true }
            guard let ekid = event.eventKitID else { return false }
            return service.event(uuid: endpointUUID)?.eventKitID == ekid
        }
    }

    /// Split the connection links by the linked contact's type. Links whose
    /// other endpoint can't be resolved (rare: unreconciled/malformed) fall into
    /// the People bucket rather than being silently dropped.
    private func connectionLinks(where type: ContactType) -> [ContactLink] {
        let links = linksStore?.links ?? []
        return links
            .filter { link in
                let other = repository.linkedContact(of: link, for: loadedContactID ?? id)
                let resolved = other?.contactType ?? .person
                return resolved == type
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        Group {
            if let contact {
                loadedContent(contact)
            } else {
                // Centered loading state — hoisted out of the List so it sits in
                // the middle of the pane, not top-left as the first row.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Width clamping is NOT applied to this Group: it would inset the List
        // (and its scroll view) from the pane edges, leaving inert dead space
        // that doesn't scroll. Instead the List stays full-bleed and each row
        // clamps + centers its own content to `ContactDetailLayout.maxContentWidth`
        // (see `centeredRowContent`), so the scrollable region reaches the pane
        // edges while content stays in a centered column. macCatalyst only —
        // see `loadedContent`.
        // The inline header (every platform) already shows the name and subtitle,
        // so an empty nav-bar title avoids showing the name twice while keeping
        // the toolbar itself (back button + Edit/star).
        .navigationTitle("")
        #if !targetEnvironment(macCatalyst)
        // Inline mode so the empty title doesn't reserve large-title space
        // above the header on the pushed iPhone/iPad detail.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .fullScreenCover(item: $fullscreenPhoto) { photo in
            ContactPhotoViewer(image: photo.image)
        }
        // Photo-change UI (picker + error) lives in one modifier to keep the
        // body's modifier chain within the type-checker's budget.
        .modifier(PhotoChangeModifier(
            presentingPhotoPicker: $presentingPhotoPicker,
            photoPickerItem: $photoPickerItem,
            photoSaveError: $photoSaveError,
            onPick: { item in Task { await applyPickedPhoto(item) } },
            onPickFileData: { data, loadError in Task { await applyRawPhotoData(data, loadError: loadError) } }
        ))
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
        // Hoisted into a method — an inline multi-statement closure here blows
        // the body's type-checker budget (see PhotoChangeModifier's note).
        .task { await performInitialLoad() }
        .task(id: contact?.contactID) {
            await loadHeaderPhoto()
        }
        .onDisappear {
            // Backstop for the edge-swipe-back gesture: the system pop bypasses
            // our custom back button, so commit here too. A no-op if
            // commitActiveEdit() already ran from a button tap.
            commitActiveEdit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkedInImportDidSave)) { _ in
            // A LinkedIn import just saved changes. Re-read so the open card
            // reflects the new fields/notes immediately instead of showing stale
            // data until re-selected. preferFresh re-reads the record + sidecar
            // fields through the fresh path. The header photo must be re-loaded
            // explicitly: the `.task(id: contact?.contactID)` trigger only
            // refires when the ID changes, and an import onto an
            // already-reconciled contact keeps the same ID — without this, an
            // imported photo stayed blank until the card was reopened.
            Task {
                // Drop the decoded-photo cache FIRST (mirrors writePhoto):
                // the loader's own didReload observer runs as a separately
                // enqueued main-queue block, so relying on it races this Task —
                // if loadHeaderPhoto wins the race, it re-serves the stale
                // pre-import image from cache and returns early.
                photoLoader.invalidate(loadedContactID ?? id)
                await loadContact(preferFresh: true)
                await loadHeaderPhoto()
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ contact: Contact) -> some View {
        // `.centeredRowContent()` is applied to each ROW's content view (inside
        // the section helpers below), NOT to the `Section`s here. A Section is a
        // structural list element, not a laid-out view, so `.frame(maxWidth:)`
        // on it doesn't reliably clamp row width — on the row content it does.
        // The List stays full-bleed so its scroll view reaches the pane edges.
        // See `centeredRowContent`.
        let list = List {
            Section {
                // Inline header on every platform: monogram + name + subtitle
                // read as a centered card, matching Apple's Contacts detail.
                // `.frame(maxWidth: .infinity)` centers it within the row;
                // `.centeredRowContent(alignment: .center)` adds the 560 column
                // clamp on Catalyst (a no-op elsewhere).
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
                // Associated Organization leads the page (people only — renders
                // nothing for orgs): the org row and its department row are the
                // highest-signal navigation on a person's card, so they sit
                // directly under the header, above the info rows.
                associatedOrganizationSection(contact)

                infoSection(contact)

                contactNotesSection(contact)

                sidecarFieldsSection

                referencedBySection(contact)

                departmentsSection(contact)

                associatedContactsSection(contact)

                groupsSection(contact)

                notesSection

                recentEventsSection

                linkedContactsSection
                linkedOrganizationsSection
                linkedEventsSection

                if debugModeEnabled {
                    debugSection(contact)
                }

                Section { activityFooter }
            }
        }
        // Inject the owned editMode binding so EditButton drives this view's own
        // .editMode state, not an ambient one we can't tear down. Reset to
        // .inactive on every contact-edit exit path.
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

    /// Editor section stack shown when `isEditingContact` is true, reusing the
    /// sheet editor's row components. The binding falls back to a throwaway
    /// empty model — never hit (the call site is gated on `editModel != nil`),
    /// but the nil-coalesce keeps the binding total without a runtime trap.
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
        ContactNotesRow(model: binding)
        editableSidecarFieldsSection
        editableNotesSection
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

    /// Notes shown while editing the contact. Mirrors the read-mode
    /// `notesSection` (same `noteRow`: inline-editable, swipe-delete, context
    /// menu) plus the same inline new-note `TextField`, and adds an "Add Dated Note"
    /// button so the note affordance is present in edit mode the way the
    /// read-mode activity footer offers it. Unlike the read section this always
    /// renders (even with zero notes) so the Add Dated Note button is always
    /// reachable. Note writes go straight through `notesStore` — immediate,
    /// independent of the CNContact `editModel`, exactly like the editable
    /// custom fields above.
    @ViewBuilder
    private var editableNotesSection: some View {
        let notes = noteItems
        Section {
            ForEach(notes, id: \.id) { note in
                noteRow(note)
                    // Delete-only rows in the active edit-mode list: apply the
                    // same offset the sibling editableSidecarFieldsSection uses
                    // so the note rows line up with the custom-field rows on
                    // Catalyst (no-op on iPhone/iPad).
                    .centeredRowContent(
                        horizontalOffset: ContactDetailLayout.deleteOnlyEditRowOffset
                    )
            }
            .onDelete { offsets in
                for i in offsets { deleteNote(notes[i].id) }
            }

            if showingNewNoteEditor {
                newNoteEditorRows
            }

            Button {
                showNewNoteEditor()
            } label: {
                Label("Add Note", systemImage: "note.text")
            }
            .disabled(notesStore == nil || showingNewNoteEditor)
            .centeredRowContent()
        } header: {
            Text("Dated Notes").centeredSectionHeader()
        }
    }

    /// Editable custom (sidecar) fields shown in contact-edit mode. The KEY
    /// (field name) is read-only; the VALUE is editable. Edits/deletes save
    /// immediately via `fieldsStore` (separate from the CNContact edit model).
    /// No add (out of scope). Hidden when the contact has no custom fields.
    @ViewBuilder
    private var editableSidecarFieldsSection: some View {
        let fields = fieldsStore?.fields ?? []
        if !fields.isEmpty {
            Section {
                ForEach(fields, id: \.id) { field in
                    EditableSidecarFieldRow(
                        name: field.field,
                        initialValue: Self.fieldDisplayValue(field),
                        isMultiline: field.type == .multilineNote,
                        onCommit: { value in
                            Task { await fieldsStore?.editField(field.id, value: value) }
                        }
                    )
                    .centeredRowContent(
                        horizontalOffset: ContactDetailLayout.deleteOnlyEditRowOffset
                    )
                }
                .onDelete { offsets in
                    for i in offsets {
                        let fieldID = fields[i].id
                        Task { await fieldsStore?.deleteField(fieldID) }
                    }
                }
            } header: {
                Text("Custom Fields").centeredSectionHeader()
            }
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
        // A red X "Cancel" mirrors the accent checkmark "Done". Cancel discards
        // any pending CNContact-model edits and dismisses — it does NOT undo
        // sidecar edits (custom fields, notes), which commit live as they're
        // made. Escape triggers Cancel via .cancelAction.
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) {
                cancelEdit()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .disabled(isSavingEdit)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")
        }
        // A single accent checkmark "Done" commits any pending CNContact-model
        // edits and dismisses; sidecar edits already saved live.
        ToolbarItem(placement: .confirmationAction) {
            Button {
                // Commit any in-progress note first (a half-typed new note or an
                // open note-row edit), so tapping Done from a focused note field
                // persists it via notesStore instead of dropping it — matching
                // the read-mode Done checkmark. A no-op when no note is focused.
                commitActiveEdit()
                Task {
                    if editModel?.isDirty == true {
                        await performInlineSave()   // saves + dismisses
                    } else {
                        cancelEdit()                // nothing to save; just dismiss
                    }
                }
            } label: {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .disabled(isSavingEdit)
            .accessibilityLabel("Done")
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
        // Star sits BEFORE Edit in the single-contact toolbar. It remains the
        // only action for a multi-selection, where it represents the aggregate
        // favorite state and updates every selected contact.
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await toggleFavoriteSelection() }
            } label: {
                Image(systemName: areFavoriteTargetsFavorited ? "star.fill" : "star")
            }
            .accessibilityLabel(areFavoriteTargetsFavorited ? "Unfavorite" : "Favorite")
        }
        if !isMultiSelection {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    Task { await beginInlineEdit() }
                }
            }
        }
    }

    /// First-appearance load (the body's `.task`). Load by `ContactID` — no
    /// reconcile on open. Reconcile is WRITE-ONLY: displaying a contact needs
    /// no GuessWho URL, an unstamped contact has no sidecar data to show
    /// (correct), and the FIRST write mints via the package's resolve-or-mint
    /// primitive.
    private func performInitialLoad() async {
        await loadContact()
        // Add-contact / LinkedIn-import entry: the record was just created;
        // open it already editing so the user lands in the form directly.
        // Gated on a successful load — starting edit on a nil contact would
        // surface a spurious "could not be found" alert.
        if startsInEditMode, contact != nil, editModel == nil {
            await beginInlineEdit()
        }
        // Stamp lastViewed ONCE per open. Lives here (runs once per
        // appearance) rather than in `loadContact()`, which re-runs on every
        // save/import/delete reload — so a card the user opens and edits is
        // "viewed" once, not once per keystroke-driven reload. NOTE:
        // `stampViewed` reconciles + mints by design (Adam: "always reconcile
        // when stamping the viewed timestamp"), so opening a never-touched
        // contact mints its GuessWho UUID. That is intended, not a leak of
        // the sidecar boundary. Fire-and-forget; never surface a stamp error.
        await stampViewed()
    }

    private func beginInlineEdit() async {
        do {
            guard let loaded = try await repository.editableContact(id: id) else {
                editFetchErrorMessage = "Contact could not be found."
                return
            }
            editModel = ContactEditModel(original: loaded)
            // Pin the list into edit mode for the duration of contact-edit so
            // .onMove drag handles appear on multi-value rows without a separate
            // toolbar EditButton — matching Apple Contacts.app, where reordering
            // is always-on while editing.
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
            // No reconcile here: editing CONTACT fields is not a GuessWho-sidecar
            // write, so it must not stamp a guesswho:// URL — an unstamped contact
            // stays unstamped until the user adds notes/tags/links/favorites, each
            // of which mints via resolve-or-mint. Just re-read the record; the
            // fresh path shows post-save state immediately instead of waiting for
            // a nav-away-and-back.
            await loadContact(preferFresh: true)
            // Stamp lastModified so the "Last Modified" sort reflects this save.
            // Runs AFTER the fresh reload so `loadedContactID` carries the
            // resolved guessWhoID. Unlike the CONTACT-field write above, this is
            // a deliberate sidecar write that resolves-or-mints by design —
            // though the view-open `stampViewed()` usually already minted, so
            // it's a no-op except on a never-viewed-yet-saved path.
            await stampModified()
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
            // recordDoesNotExist means the contact is already gone — exactly
            // what the user asked for. Treat as success.
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

    // MARK: - Edit-mode photo change

    /// Developer-facing breadcrumb for photo load/decode/save failures (the user
    /// only sees the plain-language `photoSaveError` alert). Covers the UI-layer
    /// load/decode failures that never reach the store; the CNContact save
    /// failure itself is logged by `CNContactStoreAdapter.setImageData`.
    private static let photoLog = GuessWhoLog.logger("contact.photo")

    /// Loads the picked photo's bytes, downscales them to a sane contact-photo
    /// size, and writes them to the CNContact itself (not a sidecar), so the new
    /// photo shows in Contacts.app too. Resets the picker selection so picking
    /// the same asset again re-fires.
    private func applyPickedPhoto(_ item: PhotosPickerItem) async {
        defer { photoPickerItem = nil }
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                Self.photoLog.error("picked photo returned no data")
                photoSaveError = "That photo couldn't be loaded."
                return
            }
            // Downscale off the main actor so a large asset doesn't hitch it;
            // contact photos don't need full camera resolution.
            let jpegData = await Self.normalizedPhotoData(from: rawData)
            guard let jpegData else {
                Self.photoLog.error("picked photo failed to decode (\(rawData.count) bytes)")
                photoSaveError = "That photo couldn't be processed."
                return
            }
            try await writePhoto(jpegData)
        } catch {
            Self.photoLog.error("picked photo save failed: \(error.localizedDescription)")
            photoSaveError = error.localizedDescription
        }
    }

    private func removePhoto() async {
        do {
            try await writePhoto(nil)
        } catch {
            Self.photoLog.error("photo removal failed: \(error.localizedDescription)")
            photoSaveError = error.localizedDescription
        }
    }

    /// Handles raw image bytes from a source that hands back `Data` directly
    /// rather than a `PhotosPickerItem` — a drop onto the monogram, or the
    /// Catalyst file Open panel. `rawData`/`loadError` are already hopped back to
    /// the main thread by the caller, so this method needn't reason about which
    /// thread produced them. Otherwise shares the `PhotosPicker` path's
    /// downscale/write tail.
    private func applyRawPhotoData(_ rawData: Data?, loadError: Error?) async {
        guard let rawData else {
            Self.photoLog.error("photo failed to load: \(loadError?.localizedDescription ?? "none")")
            photoSaveError = "That photo couldn't be loaded."
            return
        }
        do {
            let jpegData = await Self.normalizedPhotoData(from: rawData)
            guard let jpegData else {
                Self.photoLog.error("photo failed to decode (\(rawData.count) bytes)")
                photoSaveError = "That photo couldn't be processed."
                return
            }
            try await writePhoto(jpegData)
        } catch {
            Self.photoLog.error("photo save failed: \(error.localizedDescription)")
            photoSaveError = error.localizedDescription
        }
    }

    /// Shared write tail for set/clear: persist to Contacts, drop the decoded
    /// image cache (coarse — see `ContactPhotoLoader.invalidate`), reload the
    /// contact so `imageDataAvailable` is current, then refresh the header.
    private func writePhoto(_ imageData: Data?) async throws {
        try await repository.setContactPhoto(for: id, imageData: imageData)
        photoLoader.invalidate(loadedContactID ?? id)
        await loadContact(preferFresh: true)
        await loadHeaderPhoto()
    }

    /// Decode, downscale (longest side ≤ 1024pt), and re-encode the picked bytes
    /// as JPEG off the main actor. Returns nil if the bytes don't decode. 1024 is
    /// plenty for a contact photo and keeps the OS-thumbnailed write small.
    private static func normalizedPhotoData(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let maxSide: CGFloat = 1024
            let longest = max(image.size.width, image.size.height)
            let scaledImage: UIImage
            if longest > maxSide {
                let ratio = maxSide / longest
                let newSize = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1
                scaledImage = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
            } else {
                scaledImage = image
            }
            return scaledImage.jpegData(compressionQuality: 0.85)
        }.value
    }

    /// Inline detail header: large monogram circle, name, and a
    /// `job title · department · organization` subtitle (for an organization,
    /// the department). The nav-bar title is hidden so the name only appears
    /// once.
    @ViewBuilder
    private func headerView(_ contact: Contact) -> some View {
        VStack(spacing: 12) {
            photoCircle(contact)
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text(contact.displayName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    // Long-press (iOS) / right-click (Catalyst) to copy the name
                    // without entering the editor.
                    .copyableText(contact.displayName)

                let subtitle = headerSubtitle(contact)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .copyableText(subtitle)
                }
            }
        }
    }

    /// The circular profile image (photo or monogram fallback). Tap behavior
    /// depends on state: in edit mode it jumps to the platform picker (a
    /// translucent viewfinder overlay signals this; long-press/right-click offers
    /// Remove when a photo exists); in view mode with a photo it opens the
    /// fullscreen zoom/pan viewer; in view mode WITHOUT a photo it jumps to the
    /// picker so a first photo can be added without entering the editor.
    @ViewBuilder
    private func photoCircle(_ contact: Contact) -> some View {
        let circle = ZStack {
            if let headerPhoto {
                Image(uiImage: headerPhoto)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                if !isEditingContact {
                    Text(contact.initials)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if isEditingContact {
                // Translucent viewfinder over the circle while editing: a
                // glanceable "tap to change photo" affordance. The dark scrim
                // keeps the symbol legible over a light photo or monogram; the
                // initials are hidden above so the scrim isn't fighting them too.
                Circle()
                    .fill(Color.black.opacity(0.35))
                Image(.customPersonCropCircleViewfinder)
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }

        if isEditingContact {
            // In edit mode the circle is the "change photo" control: tap jumps
            // straight to the platform picker (no intermediate Choose/Remove
            // menu). Remove stays available via long-press / right-click.
            Button {
                presentingPhotoPicker = true
            } label: {
                circle
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change photo")
            .contextMenu {
                if contact.imageDataAvailable {
                    Button("Remove Photo", role: .destructive) {
                        Task { await removePhoto() }
                    }
                }
            }
        } else if headerPhoto != nil {
            Button {
                if let headerPhoto {
                    fullscreenPhoto = FullscreenPhoto(image: headerPhoto)
                }
            } label: {
                circle
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View photo")
        } else {
            // No photo, not editing: tapping the monogram adds a first photo
            // without opening the editor. Nothing to remove, so go straight to
            // the picker. The monogram also accepts a dropped image directly
            // (Catalyst drag from Finder/Photos, iPad split-view drag), so a
            // first photo can be set without the picker at all.
            Button {
                presentingPhotoPicker = true
            } label: {
                circle
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add photo")
            .onDrop(of: [.image], isTargeted: nil) { providers, _ in
                // Gate on the Contacts record's own flag, not `headerPhoto`:
                // this branch is also reached transiently while an existing
                // photo is still async-loading (see `loadHeaderPhoto`), and a
                // drop during that window must not silently overwrite it.
                // Restricting to `.image` (not the generic `Data` Transferable)
                // rejects non-image drops (PDF, zip) up front rather than
                // accepting them and failing later.
                guard !contact.imageDataAvailable,
                      let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
                else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, loadError in
                    Task { await applyRawPhotoData(data, loadError: loadError) }
                }
                return true
            }
        }
    }

    private func headerSubtitle(_ contact: Contact) -> String {
        // An organization's display name IS its organization name, so the
        // `job title · organization` subtitle would just repeat the title.
        // Show the department instead (a job title on an org record falls
        // back to the info rows — see `infoRows`).
        if contact.contactType == .organization {
            return contact.departmentName.trimmingCharacters(in: .whitespaces)
        }
        let parts = [contact.jobTitle, contact.departmentName, contact.organizationName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sections

    @ViewBuilder
    private func infoSection(_ contact: Contact) -> some View {
        // Label-above-value rows in roughly the order Contacts stores them, but
        // split so each multi-value TYPE (phone, email, url, address) gets its
        // OWN section — a deliberate departure from Apple's Contacts, which packs
        // every type into one card. The per-group "old"-row disclosure renders as
        // a small blue-link section FOOTER (not an inline row), so it sits outside
        // the section's grouped background. Ungrouped rows (department, dates,
        // social, IM, relations) keep their relative position by collapsing into
        // contiguous "other" sections.
        let rows = infoRows(for: contact)
        let runs = infoSectionRuns(for: rows)
        ForEach(runs) { run in
            switch run {
            case .group(let group, let visible, let hidden):
                groupedInfoSection(group: group, visible: visible, hidden: hidden)
            case .other(_, let rows):
                Section {
                    ForEach(rows) { row in
                        infoRow(row)
                            .centeredRowContent()
                    }
                }
            }
        }
    }

    /// One info section for a single multi-value field group (phone/email/url/
    /// address). No header. The group's "old"-labeled rows hide behind a "more…"
    /// section FOOTER styled as a small blue link; tapping it reveals them in the
    /// section body and the footer disappears.
    @ViewBuilder
    private func groupedInfoSection(group: InfoRowData.FieldGroup, visible: [InfoRowData], hidden: [InfoRowData]) -> some View {
        let isExpanded = expandedFieldGroups.contains(group)
        Section {
            ForEach(visible) { row in
                infoRow(row)
                    .centeredRowContent()
            }
            if isExpanded {
                // Reveal is one-way (no "less…"): expansion is per-view-instance
                // @State, so the group re-collapses only on view rebuild
                // (navigate away and back).
                ForEach(hidden) { row in
                    infoRow(row)
                        .centeredRowContent()
                }
            }
            if group == .address, !addressGuides.isEmpty {
                // Directly below the address rows, in the same section: one
                // summary row that opens the matched place's detail, where the
                // full list of guides this place sits in is enumerated.
                AddressGuidesSummaryRow(matches: addressGuides)
                    .centeredRowContent()
            }
        } footer: {
            if !isExpanded, !hidden.isEmpty {
                moreDisclosureFooter(for: group, hiddenCount: hidden.count)
            }
        }
    }

    /// Build an `InfoRow`, threading the lastInteracted stamp closure so a CALL,
    /// EMAIL, or COPY on a phone/email row registers as an interaction. The
    /// closure is fire-and-forget on the MainActor and a no-op for non-phone/
    /// email rows (which never invoke it). One helper so every call site supplies
    /// the SAME closure.
    private func infoRow(_ row: InfoRowData) -> InfoRow {
        InfoRow(data: row, onInteract: { Task { await stampInteracted() } })
    }

    @ViewBuilder
    private func contactNotesSection(_ contact: Contact) -> some View {
        let note = contact.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .centeredRowContent()
            } header: {
                Text("Contact Notes").centeredSectionHeader()
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

    /// One section's worth of info rows: either a single multi-value field group
    /// (phone/email/url/address) with its visible + hidden ("old") rows split
    /// out, or a contiguous run of ungrouped rows that share one plain section.
    private enum InfoSectionRun: Identifiable {
        case group(group: InfoRowData.FieldGroup, visible: [InfoRowData], hidden: [InfoRowData])
        /// `order` is the run's position among ungrouped runs, so two separate
        /// "other" runs (e.g. work parts before the groups, dates after) get
        /// distinct ids even when their rows would otherwise collide.
        case other(order: Int, rows: [InfoRowData])

        var id: AnyHashable {
            switch self {
            case .group(let g, _, _): return AnyHashable("group-\(g)")
            case .other(let order, _): return AnyHashable("other-\(order)")
            }
        }
    }

    /// Partition the ordered `rows` into section runs, preserving overall order.
    /// Each contiguous run of same-group rows becomes a `.group` run (visible/
    /// hidden split so the view can footer-collapse the "old" rows); contiguous
    /// ungrouped rows collapse into one `.other` run. A contact reads as:
    /// [other: dept] [group: phone] [group: email] … [other: dates, relations].
    private func infoSectionRuns(for rows: [InfoRowData]) -> [InfoSectionRun] {
        var runs: [InfoSectionRun] = []
        var otherOrder = 0
        var index = rows.startIndex
        while index < rows.endIndex {
            let row = rows[index]
            guard let group = row.group else {
                // Consume the contiguous run of ungrouped rows into one section.
                var runEnd = index
                while runEnd < rows.endIndex, rows[runEnd].group == nil { runEnd += 1 }
                runs.append(.other(order: otherOrder, rows: Array(rows[index..<runEnd])))
                otherOrder += 1
                index = runEnd
                continue
            }
            // Consume the whole contiguous run for this group at once.
            var runEnd = index
            while runEnd < rows.endIndex, rows[runEnd].group == group { runEnd += 1 }
            let run = rows[index..<runEnd]
            // Deliberate: when EVERY value in a group is "old", `visible` is empty
            // and the section renders as a lone "more…" footer with no row above.
            // That upholds the rule — "old" values always hide behind "more…" —
            // rather than special-casing all-old groups.
            runs.append(.group(
                group: group,
                visible: run.filter { !$0.isOld },
                hidden: run.filter { $0.isOld }
            ))
            index = runEnd
        }
        return runs
    }

    /// The "more…" section footer for a field group's hidden "old" rows. Shows
    /// the hidden count ("more… (2)") in small blue-link style (footnote + tint),
    /// outside the section's grouped background. Tap is one-way — see
    /// `groupedInfoSection`.
    @ViewBuilder
    private func moreDisclosureFooter(for group: InfoRowData.FieldGroup, hiddenCount: Int) -> some View {
        Button {
            withAnimation {
                _ = expandedFieldGroups.insert(group)
            }
        } label: {
            Text("more… (\(hiddenCount))")
                .font(.footnote)
                .foregroundStyle(.tint)
                // Pin to the leading edge so it reads as a normal left-aligned
                // footer link — without this the Button collapses to its
                // intrinsic width and could center.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Footer styling: the Catalyst 560-column clamp so the link lines up with
        // the section's rows, plus breathing room *below* (not above) so the link
        // tucks under the section it discloses rather than floating toward the
        // next one.
        .centeredSectionFooter()
    }

    /// "Recent Events": up to 10 EventKit events matched to this contact by
    /// email attendee (any address on the card) or by location (an event whose
    /// location text contains one of the contact's street lines). Distinct from
    /// the user-curated "Linked Events" section. Tapping a row pushes the event
    /// detail; the `eventKitID` hint lets its adopt-on-load path mint a sidecar
    /// on first open.
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
        .contextMenu {
            if let link = eventLink(for: event) {
                // Already in "Linked Events" — offer to remove that curated link.
                Button(role: .destructive) {
                    removeEventLink(link.id)
                } label: {
                    Label("Unlink Event", systemImage: "calendar.badge.minus")
                }
            } else {
                Button {
                    Task { await linkRecentEvent(event) }
                } label: {
                    Label("Link Event", systemImage: "calendar.badge.plus")
                }
            }
        }
    }

    /// Long-press "Link Event" on a recent-event row. Recent events are
    /// EventKit-sourced, so `event.id` is the synthetic
    /// `Event.stableID(forEventKitID:)` with no sidecar behind it — linking
    /// that UUID directly would persist a link whose event endpoint
    /// `service.event(uuid:)` can never resolve, rendering "(Unknown event)".
    /// Resolve-or-mint the real sidecar UUID first (`linkEvent` dedups
    /// against an existing sidecar internally), mirroring
    /// `EventLinkSheet.dedupAndLink`.
    private func linkRecentEvent(_ event: Event) async {
        let eventUUID: String
        if let ekid = event.eventKitID {
            do {
                eventUUID = try await service.linkEvent(toEventKitID: ekid).uuidString
            } catch {
                service.recordError("link event failed: \(error.localizedDescription)")
                return
            }
        } else {
            // Sidecar-only event — its id IS the sidecar UUID.
            eventUUID = event.id.uuidString
        }
        await addEventLink(eventUUID: eventUUID, note: "")
    }

    @ViewBuilder
    private func referencedBySection(_ contact: Contact) -> some View {
        let backrefs = repository.contactsReferencing(contact: contact)
        if !backrefs.isEmpty {
            // Inbound relations read INVERSE: "Alice's mother is Bob" becomes,
            // on Bob's screen, a row showing Alice captioned "their mother" (Bob
            // is Alice's mother). Promoting the name to primary and demoting the
            // label to a "their <label>" caption keeps the direction unambiguous.
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

    /// The organization record inferred for a person from their Contacts
    /// "company" field (see `organizationContact(named:)`), or nil when the
    /// person names no company, the company matches no org record, or the match
    /// is the person themselves. People only.
    private func associatedOrganization(of contact: Contact) -> Contact? {
        guard contact.contactType == .person,
              let organization = repository.organizationContact(named: contact.organizationName),
              organization.contactID != contact.contactID else { return nil }
        return organization
    }

    /// Inferred membership on a person's page: when their Contacts "company"
    /// field names an organization record, show that organization as a
    /// read-only navigation row. The association remains owned by the person's
    /// company field, matching the inverse "Associated Contacts" section. When
    /// the person also names a department, a second row taps straight through to
    /// that organization's department list (the person's own department bucket).
    @ViewBuilder
    private func associatedOrganizationSection(_ contact: Contact) -> some View {
        if let organization = associatedOrganization(of: contact) {
            let department = contact.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
            Section {
                associatedOrganizationRow(organization)
                    .centeredRowContent()
                if !department.isEmpty {
                    departmentRow(department, organization: organization)
                        .centeredRowContent()
                }
            } header: {
                Text("Associated Organization").centeredSectionHeader()
            }
        }
    }

    private func associatedOrganizationRow(_ organization: Contact) -> some View {
        Button {
            pushContactReference(ContactReference(id: organization.contactID))
        } label: {
            ActivityRowLayout {
                ContactAvatar(contact: organization, diameter: 20)
            } content: {
                Text(organization.displayName)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Inferred membership on an organization's page: people whose Contacts
    /// "company" field names this organization (see
    /// `ContactsRepository.contactsAssociated(with:)`). Mirrors "Referenced
    /// By": rows are read-only — the association lives in each person's own
    /// company field, so there's nothing to edit or delete here — and tap
    /// through to the person. Organizations only; hidden when empty.
    @ViewBuilder
    private func associatedContactsSection(_ contact: Contact) -> some View {
        if contact.contactType == .organization {
            let people = repository.contactsAssociated(with: contact)
            if !people.isEmpty {
                Section {
                    ForEach(people, id: \.contactID) { person in
                        associatedContactRow(person)
                            .centeredRowContent()
                    }
                } header: {
                    Text("Associated Contacts").centeredSectionHeader()
                }
            }
        }
    }

    @ViewBuilder
    private func associatedContactRow(_ person: Contact) -> some View {
        Button {
            pushContactReference(ContactReference(id: person.contactID))
        } label: {
            ActivityRowLayout {
                ContactAvatar(contact: person, diameter: 20)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .foregroundStyle(.tint)
                    if !person.jobTitle.isEmpty {
                        Text(person.jobTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Departments seen on an organization's page: the distinct department names
    /// carried by the people associated with this organization (see
    /// `ContactsRepository.departments(in:)`). Each row taps through to a list of
    /// the people in that department (`DepartmentReference` → the scene delegate's
    /// department-members list). Organizations only; hidden when no associated
    /// person names a department.
    @ViewBuilder
    private func departmentsSection(_ contact: Contact) -> some View {
        if contact.contactType == .organization {
            let departments = repository.departments(in: contact)
            if !departments.isEmpty {
                Section {
                    ForEach(departments, id: \.self) { department in
                        departmentRow(department, organization: contact)
                            .centeredRowContent()
                    }
                } header: {
                    Text("Departments").centeredSectionHeader()
                }
            }
        }
    }

    @ViewBuilder
    private func departmentRow(_ department: String, organization: Contact) -> some View {
        Button {
            pushDepartmentReference(
                DepartmentReference(organizationID: organization.contactID, department: department)
            )
        } label: {
            ActivityRowLayout(systemImage: "person.2") {
                Text(department)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Contacts.app groups this record belongs to. Shown for BOTH people and
    /// organizations — a Contacts group holds either — so unlike
    /// `departmentsSection` there is no `contactType` gate. Each row taps through
    /// to that group's member list (the same `GroupMembersListViewController` the
    /// Groups tab pushes). Hidden when the record is in no groups.
    @ViewBuilder
    private func groupsSection(_ contact: Contact) -> some View {
        if !memberGroups.isEmpty {
            Section {
                ForEach(memberGroups, id: \.localID) { group in
                    groupRow(group)
                        .centeredRowContent()
                }
            } header: {
                Text("Groups").centeredSectionHeader()
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: ContactGroup) -> some View {
        // Read through the @Observable favorites cache so the star repaints when
        // the group is favorited/unfavorited from here or anywhere else.
        let isFavorited = favoritesStore.isFavorite(kind: .group, id: group.localID)
        Button {
            pushGroupReference(GroupReference(group: group))
        } label: {
            ActivityRowLayout(systemImage: "person.3") {
                HStack(spacing: 6) {
                    Text(group.name.isEmpty ? "Group" : group.name)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isFavorited {
                        Image(systemName: "star.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorited")
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        // A group has no detail screen to host a star toolbar button, so the
        // favorite toggle lives in the row's context menu (long-press / right-
        // click), mirroring the recent-event row's link menu.
        .contextMenu {
            Button {
                favoritesStore.toggle(kind: .group, id: group.localID)
            } label: {
                if isFavorited {
                    Label("Unfavorite", systemImage: "star.slash")
                } else {
                    Label("Favorite", systemImage: "star")
                }
            }
        }
    }

    private func infoRows(for contact: Contact) -> [InfoRowData] {
        var rows: [InfoRowData] = []

        // Skip the name parts (in the inline header) and whatever the subtitle
        // already renders (see `headerSubtitle`): for a person that's job title,
        // department, and organization; for an organization the subtitle is the
        // department, so job title stays here instead. Phonetic organization is
        // never in the header. (A person's department may ALSO appear as the
        // navigable second row in the Associated Organization section — that's
        // deliberate: the subtitle states it, the row navigates to it.)
        let workParts: [(String, String)] = contact.contactType == .organization
            ? [
                ("job title", contact.jobTitle),
                ("phonetic organization", contact.phoneticOrganizationName),
            ]
            : [
                ("phonetic organization", contact.phoneticOrganizationName),
            ]
        for (label, value) in workParts where !value.isEmpty {
            rows.append(.text(label: label, value: value))
        }

        // Phone/email/url/address groups partition into non-"old" rows first,
        // then the "old"-labeled ones, so visible rows always precede hidden ones
        // regardless of how Contacts stored the values; the view collapses each
        // group's trailing "old" rows behind a "more…" disclosure (see
        // `infoSection`). `groupOccurrence` is the row's index within its
        // partitioned group, keeping the id unique even for duplicate values.
        let phones = contact.phoneNumbers.stablePartitionedByOldLabel { $0.label }
        for (i, item) in phones.enumerated() {
            var row = InfoRowData.phone(label: localizedLabel(item.label), number: item.value, isOld: item.label.isOldFieldLabel)
            row.groupOccurrence = i
            rows.append(row)
        }
        let emails = contact.emailAddresses.stablePartitionedByOldLabel { $0.label }
        for (i, item) in emails.enumerated() {
            var row = InfoRowData.email(label: localizedLabel(item.label), address: item.value, isOld: item.label.isOldFieldLabel)
            row.groupOccurrence = i
            rows.append(row)
        }
        let urls = contact.userVisibleURLAddresses.stablePartitionedByOldLabel { $0.label }
        for (i, item) in urls.enumerated() {
            var row = InfoRowData.url(label: localizedLabel(item.label), urlString: item.value, isOld: item.label.isOldFieldLabel)
            row.groupOccurrence = i
            rows.append(row)
        }

        let addresses = contact.postalAddresses.stablePartitionedByOldLabel { $0.label }
        for (i, item) in addresses.enumerated() {
            var row = InfoRowData.address(label: localizedLabel(item.label), address: item.value, isOld: item.label.isOldFieldLabel)
            row.groupOccurrence = i
            rows.append(row)
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
            rows.append(socialProfileRow(item))
        }
        for item in contact.instantMessageAddresses {
            rows.append(.text(label: instantMessageLabel(item), value: item.value.username))
        }
        let lookup = repository.lookupByDisplayName()
        let selfID = contact.contactID
        for item in contact.contactRelations {
            let key = item.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Compare by ContactID (effective GuessWho identity), not raw
            // localID, so a relation pointing at this very contact is excluded by
            // stable identity, not the transient identifier. Mint the match's
            // ContactID once (it re-parses the GuessWho URL) and reuse it.
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

        // No reconcile-outcome / raw-sidecar-envelope readouts: reconcile is a
        // package-internal side effect the view doesn't drive, so there's no
        // app-side outcome to show, and surfacing it would mean retaining new
        // per-contact package state purely for a debug row. The package-vended
        // identity diagnostics above stay under the debug carve-out.

        return rows
    }

    // MARK: - Notes / Linked Contacts / Organizations / Events
    //
    // One section per kind, each sorted createdAt ASC.

    @ViewBuilder
    private var notesSection: some View {
        let notes = noteItems
        if !notes.isEmpty || showingNewNoteEditor {
            Section {
                ForEach(notes, id: \.id) { note in
                    noteRow(note)
                        .centeredRowContent()
                }
                .onDelete { offsets in
                    for i in offsets { deleteNote(notes[i].id) }
                }

                if showingNewNoteEditor {
                    newNoteEditorRows
                }
            } header: {
                Text("Dated Notes").centeredSectionHeader()
            }
        }
    }

    @ViewBuilder
    private var linkedContactsSection: some View {
        linkSection(title: "Linked Contacts", links: linkedPeople,
                    delete: { deleteLink($0) }) { connectionRow($0) }
    }

    @ViewBuilder
    private var linkedOrganizationsSection: some View {
        linkSection(title: "Linked Organizations", links: linkedOrganizations,
                    delete: { deleteLink($0) }) { connectionRow($0) }
    }

    @ViewBuilder
    private var linkedEventsSection: some View {
        // Event links delete via removeEventLink (NOT deleteLink).
        linkSection(title: "Linked Events", links: linkedEventItems,
                    delete: { removeEventLink($0) }) { linkedEventRow($0) }
    }

    /// Shared section shell for a list of `ContactLink`s with a row builder and
    /// swipe-to-delete. Delete differs by kind (contact/org links use
    /// `deleteLink`, event links use `removeEventLink`). Hidden when empty.
    @ViewBuilder
    private func linkSection(
        title: String,
        links: [ContactLink],
        delete: @escaping (UUID) -> Void,
        @ViewBuilder row: @escaping (ContactLink) -> some View
    ) -> some View {
        if !links.isEmpty {
            Section {
                ForEach(links, id: \.id) { link in
                    row(link).centeredRowContent()
                }
                .onDelete { offsets in
                    for i in offsets { delete(links[i].id) }
                }
            } header: {
                Text(title).centeredSectionHeader()
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
            // No UUID gate: the link write resolves-or-mints the GuessWho UUID
            // internally, so a never-touched contact can be linked. `linksStore`
            // is built for every loaded contact, so this only disables until the
            // first load finishes.
            .disabled(linksStore == nil)
            .sheet(isPresented: $showingAddLinkSheet) {
                if let linksStore {
                    // The picker hands back the far endpoint's ContactID; the
                    // store's async addLink resolves-or-mints BOTH endpoints.
                    // The store is @Observable, so adding the link re-renders the
                    // connection rows, each resolving its other endpoint.
                    AddLinkSheet(currentContactID: id, kind: .person) { otherID, note in
                        Task { await linksStore.addLink(to: otherID, note: note) }
                    }
                }
            }

            Divider()

            activityFooterButton(
                title: "Link Org",
                systemImage: "building.2",
                action: { showingAddOrgLinkSheet = true }
            )
            // "Link Org" shares the "Link Contact" write path — an organization
            // is a Contact, so the link record and store are identical; only
            // the picker's eligibility filter differs.
            .disabled(linksStore == nil)
            .sheet(isPresented: $showingAddOrgLinkSheet) {
                if let linksStore {
                    AddLinkSheet(currentContactID: id, kind: .organization) { otherID, note in
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

    /// The inline new-note editor: body text field plus a date picker so the
    /// user can back-date the note. Shared by the read-mode `notesSection`
    /// and the contact-edit `editableNotesSection`. The picker binding maps
    /// nil (untouched) to "now" for display; commit stamps the actual save
    /// time unless the user picked a date.
    @ViewBuilder
    private var newNoteEditorRows: some View {
        TextField("Add a dated note", text: $newNoteText, axis: .vertical)
            .lineLimit(3...)
            .focused($noteFocus, equals: .newNote)
            .centeredRowContent()
        DatePicker(
            "Date",
            selection: Binding(
                get: { newNoteDate ?? Date() },
                set: { newNoteDate = $0 }
            ),
            displayedComponents: [.date, .hourAndMinute]
        )
        .centeredRowContent()
    }

    @ViewBuilder
    private func noteRow(_ note: ContactNote) -> some View {
        if editingNoteID == note.id {
            ActivityRowLayout(systemImage: "text.rectangle") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("", text: $draftBody, axis: .vertical)
                        .lineLimit(3...)
                        .focused($noteFocus, equals: .noteRow(note.id))
                    DatePicker(
                        "Date",
                        selection: $draftNoteDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
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

    private func showNewNoteEditor() {
        guard notesStore != nil else { return }
        showingNewNoteEditor = true
        newNoteDate = nil
        noteFocus = .newNote
    }

    /// The ContactID derived from the LOADED contact, carrying its current
    /// `guessWhoID` (which the nav `id` lacks after a first-write mint). The
    /// repository's sidecar reads (`eventLinks(for:)`) key on the passed
    /// ContactID's `guessWhoID`, so reads must use THIS, not the stale nav `id`.
    /// nil only before the first load resolves a contact.
    private var loadedContactID: ContactID? {
        guard let contact else { return nil }
        return contact.contactID
    }

    private var isMultiSelection: Bool {
        selectedContactIDs.count > 1
    }

    /// Current IDs for the favorite targets. Re-resolving through the repository
    /// is important after a first favorite mints a GuessWho ID: the navigation
    /// IDs captured when selection began may still be pre-mint IDs.
    private var favoriteTargetIDs: [ContactID] {
        let targets = isMultiSelection ? selectedContactIDs : [loadedContactID ?? id]
        return targets.map { repository.contact(id: $0)?.contactID ?? $0 }
    }

    private var areFavoriteTargetsFavorited: Bool {
        let targets = favoriteTargetIDs
        return !targets.isEmpty && targets.allSatisfy(favoritesStore.isFavorite)
    }

    private func toggleFavoriteSelection() async {
        // A mixed selection converges to all-favorited; only an already fully
        // favorited selection converges to none. Skip contacts already in the
        // desired state so a mixed selection never inverts its favorited subset.
        let shouldFavorite = !areFavoriteTargetsFavorited
        for targetID in favoriteTargetIDs {
            guard favoritesStore.isFavorite(targetID) != shouldFavorite else { continue }
            do {
                _ = try await repository.toggleFavorite(targetID)
            } catch {
                // Continue through the selection so one failed contact does not
                // prevent the remaining requested updates. The observable reload
                // below reflects whichever writes actually landed.
                service.recordError("toggle favorite failed: \(error.localizedDescription)")
            }
        }

        // Favoriting may mint IDs, including for the visible front contact.
        await loadContact()
        favoritesStore.reload()
    }

    private func addEventLink(eventUUID: String, note: String) async {
        do {
            // The write resolves-or-mints the CONTACT endpoint's GuessWho UUID,
            // so a never-touched contact can link an event.
            _ = try await repository.addEventLink(for: id, eventUUID: eventUUID, note: note)
        } catch {
            service.recordError("add contact-event link failed: \(error.localizedDescription)")
        }
        // A first link may have minted the UUID, re-keying the cache. Re-resolve
        // the loaded contact off the reconcile-stable `contact(id:)` so
        // `loadedContactID` carries the new guessWhoID, then re-read event links
        // and re-key the notes/links stores onto the minted identity. Targeted
        // re-read (not a full loadContact) to avoid refiring refreshLinkedEvents;
        // the freshly-added event refreshes when the user opens its detail view.
        contact = repository.contact(id: id)
        if let contact { await rebuildSidecarStores(for: contact) }
        eventLinks = await repository.eventLinks(for: loadedContactID ?? id)
    }

    private func removeEventLink(_ id: UUID) {
        // Clear edit state first (synchronously, at tap time): setLinkNote on
        // a soft-deleted link undeletes it, so a pending edit must NOT commit
        // after the delete lands. The delete WRITE is synchronous too — only
        // the re-read scan below rides a Task — so UI-event ordering against
        // a committed edit is structural, not enqueue-order-dependent.
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
        // Do NOT refire refreshLinkedEvents. The contact already has a UUID (it
        // had event links to remove), so reading off `loadedContactID` resolves;
        // `self.id` is the fallback.
        Task { eventLinks = await repository.eventLinks(for: loadedContactID ?? self.id) }
    }

    // MARK: - Loading & reconcile

    private var sidecarUnavailableReason: String? {
        if case .unavailable(let reason) = service.sidecarLocation { return reason }
        return nil
    }

    private func loadContact(preferFresh: Bool = false) async {
        // Resolve the live contact off the view's captured `ContactID`.
        // `contact(id:)` is reconcile-stable (chases the guessWhoID pointer when
        // present, else falls back to the token's always-present `localID`), so
        // the captured `id` keeps resolving even after a first-write reconcile
        // re-keys the contact's effective identity — no separately threaded
        // `localID` needed.
        let loaded: Contact?
        if preferFresh, let fresh = try? await repository.editableContact(id: id) {
            // Post-save read: unifiedContact(withIdentifier:) is more consistent
            // than the enumerate path the repository cache uses on Catalyst right
            // after a write.
            loaded = fresh
        } else {
            loaded = repository.contact(id: id)
        }
        if let loaded {
            // Gather the sidecar-backed state BEFORE publishing `contact`:
            // the store and link reads are async scans now, and publishing
            // the card first would paint it with the link sections missing,
            // then pop them in a beat later. Collecting into locals and
            // assigning together restores the old single-paint appearance —
            // only the I/O moved off the main actor.
            await rebuildSidecarStores(for: loaded)
            // Event links keyed on the LOADED contact's ContactID (carries
            // the current guessWhoID; the nav `id` lacks it after a
            // first-write mint). Empty for an unreconciled contact.
            let linkID = loaded.contactID
            let fetchedEventLinks = await repository.eventLinks(for: linkID)
            contact = loaded
            eventLinks = fetchedEventLinks
            // The EventKit cache refresh stays on SyncService (an
            // event-surface concern). The event UUIDs derive from the links
            // just read (one disk scan, not a second `linkedEventUUIDs`
            // walk) via the repository's pure per-link resolver, so the app
            // still builds no `.contact` SidecarKey. Initial load only.
            let eventUUIDs = fetchedEventLinks.compactMap {
                repository.eventEndpointUUID(of: $0, for: linkID)
            }
            await service.refreshLinkedEvents(eventUUIDs: eventUUIDs)
            await reloadRecentEvents(for: loaded)
            await reloadGroups(for: loaded)
            await reloadAddressGuides(for: loaded)
        } else {
            contact = nil
            // Contact disappeared from the store (e.g. deleted via the edit
            // sheet). Tear down sidecar-bound state so nothing keeps reading/
            // writing a dead identity while the view animates away. Safe to nil
            // even if the caller isn't about to dismiss — a re-load reconstructs
            // them.
            notesStore = nil
            fieldsStore = nil
            linksStore = nil
            eventLinks = []
            recentEvents = []
            memberGroups = []
        }
    }

    // MARK: - Timestamp stamping
    //
    // Three fire-and-forget stamps record when the user last viewed, modified,
    // or interacted with a contact, feeding the global time-ordered sorts. Each
    // routes through the repository (which resolves-or-mints the GuessWho UUID as
    // part of the write), runs on the MainActor, and swallows errors with `try?`
    // — a failed stamp must never block the UI or surface to the user. All three
    // prefer `loadedContactID` (carries the resolved `guessWhoID`), falling back
    // to the nav `id` before the first load resolves a contact.

    /// Stamp `lastViewed` for the open contact. Called once per open from the
    /// view's `.task`. See that call site for the once-per-open rationale and
    /// the reconcile-on-view note.
    private func stampViewed() async {
        try? await repository.stampViewed(loadedContactID ?? id)
    }

    /// Stamp `lastModified` after a successful inline save.
    private func stampModified() async {
        try? await repository.stampModified(loadedContactID ?? id)
    }

    /// Stamp `lastInteracted` when the user calls, emails, or copies a phone /
    /// email value. (URL and date taps do NOT count as interactions.)
    private func stampInteracted() async {
        try? await repository.stampInteracted(loadedContactID ?? id)
    }

    /// (Re)build the notes/links stores keyed on the LOADED contact's ContactID
    /// — NOT the nav `id`, whose `guessWhoID` is still nil after a first-write
    /// mint: `repository.notes(for:)` / `links(for:)` read the `guessWhoID`
    /// directly off the passed ContactID. Rebuild when that identity changes — a
    /// first-write/Case-A mint stamps a fresh UUID, and a Case-D reconcile picks
    /// a winner UUID and deletes the loser's sidecar, so a store bound to the old
    /// identity would read/write a dead file. Built for EVERY contact (even
    /// unreconciled): reads return empty until a write reconciles + mints, so
    /// notes/links can be added to a never-touched contact.
    private func rebuildSidecarStores(for loaded: Contact) async {
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
        // The links store constructs EMPTY (its read walks every link sidecar,
        // so it can't run in init) — always await a reload, fresh or reused.
        if linksStore?.id != loadedID {
            linksStore = ContactLinksStore(repository: repository, id: loadedID)
        }
        await linksStore?.reload()
    }

    /// Fetch up to 10 EventKit events matched to this contact — either the
    /// contact appears as an attendee (matched by any email on the card) or the
    /// event's location text contains one of the contact's street lines. Runs
    /// on a background queue inside `SyncService.recentEvents`; the awaited
    /// result resumes on the main actor. No-op when the contact has neither an
    /// email nor a street address.
    private func reloadRecentEvents(for contact: Contact) async {
        let myLoadID = UUID()
        recentEventsLoadID = myLoadID
        let emails = Set(contact.emailAddresses.map { $0.value })
        // Street lines drive location matching — city/state alone would sweep
        // in every unrelated venue in the same town.
        let addresses = Set(
            contact.postalAddresses
                .map { $0.value.street.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !(emails.isEmpty && addresses.isEmpty) else {
            // Synchronous from the token bump above — no suspension, no race.
            recentEvents = []
            return
        }
        let fetched = await service.recentEvents(forEmails: emails, addresses: addresses, limit: 10)
        // Bail if a newer reload started while this fetch was in flight (see
        // `recentEventsLoadID`).
        guard recentEventsLoadID == myLoadID else { return }
        recentEvents = fetched
    }

    /// Fetch the imported guides whose places' addresses contain one of this
    /// contact's structured street lines, for the guide rows under the address
    /// section. Guarded by a load token so a stale in-flight scan can't
    /// overwrite a newer result — see `reloadRecentEvents`.
    private func reloadAddressGuides(for contact: Contact) async {
        let myLoadID = UUID()
        addressGuidesLoadID = myLoadID
        let streets = Set(
            contact.postalAddresses
                .map { $0.value.street.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !streets.isEmpty else {
            // Synchronous from the token bump above — no suspension, no race.
            addressGuides = []
            return
        }
        let fetched = await service.guides(containingAddresses: streets)
        guard addressGuidesLoadID == myLoadID else { return }
        addressGuides = fetched
    }

    /// Fetch the Contacts.app groups this record belongs to (a membership scan
    /// over every group, so it runs after the card paints rather than blocking
    /// it). Guarded by a load token so a stale in-flight scan can't overwrite a
    /// newer result — see `reloadRecentEvents`.
    private func reloadGroups(for contact: Contact) async {
        let myLoadID = UUID()
        memberGroupsLoadID = myLoadID
        let fetched = await repository.groups(containing: contact)
        guard memberGroupsLoadID == myLoadID else { return }
        memberGroups = fetched
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
        // Switching focus to an existing note commits the pending new-note
        // editor too (persists it if non-empty, clears the editor if empty) —
        // otherwise the empty "Add a dated note" field would linger after the focus
        // moves away.
        if showingNewNoteEditor {
            commitNewNote()
        }
        editingNoteID = note.id
        draftBody = note.body
        editStartSnapshot = note.body
        draftNoteDate = note.createdAt
        editStartDateSnapshot = note.createdAt
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
            // Keyboard focus can drop while an editor is still open (e.g.
            // after interacting with a note's date picker) — commit whatever
            // editor is pending rather than silently discarding it.
            if showingNewNoteEditor { commitNewNote() }
            if editingNoteID != nil { commitRowEditIfChanged() }
            if editingLinkID != nil { commitLinkEditIfChanged() }
        }
        noteFocus = nil
    }

    private func commitNewNote() {
        let body = newNoteText
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let notesStore {
            // A nil date means the picker was never touched — stamp "now" at
            // save time (the store's default), not editor-open time.
            let date = newNoteDate
            Task { await notesStore.addNote(body: body, date: date) }
        }
        newNoteText = ""
        newNoteDate = nil
        showingNewNoteEditor = false
    }

    private func commitRowEditIfChanged() {
        guard let id = editingNoteID else { return }
        let proposed = draftBody
        let snapshot = editStartSnapshot
        let proposedDate = draftNoteDate
        let dateSnapshot = editStartDateSnapshot
        editingNoteID = nil
        draftBody = ""
        editStartSnapshot = ""
        let dateChanged = proposedDate != dateSnapshot
        if proposed == snapshot && !dateChanged { return }
        if let notesStore {
            // Pass the date only when the user moved it, so an untouched
            // picker preserves the note's exact stored timestamp.
            Task {
                await notesStore.editNote(id, newBody: proposed, date: dateChanged ? proposedDate : nil)
            }
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
            // Synchronous write; only the store's re-read scan rides a Task.
            // Inline writes keep UI-event ordering structural — a committed
            // edit can never land after a subsequently-tapped delete.
            linksStore?.setNote(id: id, note: proposed)
        } else if eventLinks.contains(where: { $0.id == id }) {
            do {
                // A contact↔event link's note edit goes through the shared
                // repository link-note write (keyed on the link's own UUID, no
                // contact resolve needed), then re-reads the event links.
                try repository.setLinkNote(id: id, note: proposed)
                Task { eventLinks = await repository.eventLinks(for: loadedContactID ?? self.id) }
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
        // Clear edit state first: setLinkNote on a soft-deleted link undeletes
        // it, so a pending edit must NOT commit after the delete lands.
        if editingLinkID == id {
            editingLinkID = nil
            draftLinkNote = ""
            editLinkStartSnapshot = ""
            if case .linkRow(let focused) = noteFocus, focused == id {
                noteFocus = nil
            }
        }
        // Synchronous write inside; the store defers only its re-read scan.
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
        // The CN per-profile label is usually empty; the service (twitter,
        // linkedin, …) is the meaningful identifier here.
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

    /// The info row for one social profile. Contacts stores the LinkedIn
    /// profile as a bare username (the URL is derived from it — see
    /// `LinkedInContactSeed`), which used to render as dead text; rebuild the
    /// canonical public profile URL so the row taps through to the profile.
    /// A profile that carries only a stored URL is likewise tappable. Anything
    /// else keeps the plain-text fallback.
    private func socialProfileRow(_ item: LabeledSocialProfile) -> InfoRowData {
        let label = socialProfileLabel(item)
        let profile = item.value
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLinkedIn = profile.service.caseInsensitiveCompare("linkedin") == .orderedSame
            || item.label.caseInsensitiveCompare("linkedin") == .orderedSame
        if isLinkedIn, !username.isEmpty {
            // slug(from:) unwraps a full URL mistakenly stored in the username
            // field; a bare slug passes through unchanged.
            let slug = LinkedInURL.slug(from: username) ?? username
            return InfoRowData(label: label, kind: .url(urlString: "https://www.linkedin.com/in/\(slug)"))
        }
        let storedURL = profile.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty, storedURL.lowercased().hasPrefix("http") {
            return InfoRowData(label: label, kind: .url(urlString: storedURL))
        }
        return .text(label: label, value: socialProfileValue(profile))
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

private extension String {
    /// True when this raw Contacts label is the user's custom "old" label.
    /// Standard CN labels arrive wrapped (e.g. `_$!<Home>!$_`), so they never
    /// collide with this plain, case-insensitive match.
    var isOldFieldLabel: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "old"
    }
}

private extension Array {
    /// Reorder so every non-"old"-labeled element precedes every "old"-labeled
    /// one, preserving each subgroup's original order. `label` extracts the raw
    /// Contacts label (the various labeled-value types don't share a protocol).
    /// Lets the detail view collapse the trailing "old" rows behind a "more…"
    /// disclosure regardless of how Contacts ordered the values.
    func stablePartitionedByOldLabel(_ label: (Element) -> String) -> [Element] {
        filter { !label($0).isOldFieldLabel } + filter { label($0).isOldFieldLabel }
    }
}

/// Bundles the edit-mode photo-change surfaces — the platform picker
/// (`PhotosPicker` on iOS/iPadOS, a file Open panel on Catalyst) and the failure
/// alert — into one modifier, extracted from `ContactDetailView.body` to keep
/// that view's modifier chain within the type-checker's budget.
///
/// Catalyst gets a real file-system Open panel, not the Photos picker: Catalyst
/// users expect to browse the filesystem (Finder, AirDropped files, external
/// drives), and `PhotosPicker` only surfaces the Photos library grid there.
private struct PhotoChangeModifier: ViewModifier {
    @Binding var presentingPhotoPicker: Bool
    @Binding var photoPickerItem: PhotosPickerItem?
    @Binding var photoSaveError: String?
    let onPick: (PhotosPickerItem) -> Void
    let onPickFileData: (Data?, Error?) -> Void

    func body(content: Content) -> some View {
        content
            #if targetEnvironment(macCatalyst)
            // Catalyst drives a native, in-process `NSOpenPanel` through the
            // AppKitBridge bundle rather than a `UIDocumentPickerViewController`:
            // the latter's presenter detaches from the window mid-present on
            // Catalyst, so the powerbox never shows and the whole window
            // deadlocks (no dialog, frozen to mouse input). The bundle runs the
            // panel modelessly on the main thread and calls back with the URLs.
            //
            // Hung off `onChange(of: presentingPhotoPicker)` rather than a
            // `.sheet` so existing call sites that just set
            // `presentingPhotoPicker = true` keep working. Reset the flag
            // immediately (the panel is its own window, not a SwiftUI
            // presentation) so the next tap re-triggers.
            .onChange(of: presentingPhotoPicker) { _, isPresenting in
                guard isPresenting else { return }
                presentingPhotoPicker = false
                presentOpenPanelForPhoto()
            }
            #else
            .photosPicker(isPresented: $presentingPhotoPicker, selection: $photoPickerItem, matching: .images)
            .onChange(of: photoPickerItem) { _, newItem in
                guard let newItem else { return }
                onPick(newItem)
            }
            #endif
            .alert(
                "Couldn't update photo",
                isPresented: Binding(
                    get: { photoSaveError != nil },
                    set: { if !$0 { photoSaveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { photoSaveError = nil }
            } message: {
                Text(photoSaveError ?? "")
            }
    }

    #if targetEnvironment(macCatalyst)
    /// Drives the native macOS file Open panel (via the in-process AppKitBridge
    /// bundle) and feeds the picked image's bytes into the shared downscale/write
    /// tail as raw `Data`, matching the `NSItemProvider` shape the drag-and-drop
    /// path uses. The panel's completion fires on the main thread; we read the
    /// file off it so a large image can't stall the UI, then hop back.
    private func presentOpenPanelForPhoto() {
        guard let bridge = AppKitBridgeLoader.shared else {
            // Bundle failed to load — surface a plain-language error rather than
            // silently no-op'ing the tap. (AppKitBridgeLoader logs the debug
            // breadcrumbs.)
            photoSaveError = "The photo picker couldn't be opened."
            return
        }
        bridge.presentOpenPanel(
            allowedExtensions: ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "bmp", "webp"],
            allowsMultiple: false
        ) { urls in
            // Main thread; an empty array means the user cancelled.
            guard let url = urls.first else { return }
            // The in-process panel selection is already blessed against the
            // sandbox, so a same-launch read needs no security-scoped bracket;
            // we keep the defensive start/stop anyway (harmless) and read off
            // the main thread so a large file doesn't stall the UI.
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    DispatchQueue.main.async { onPickFileData(data, nil) }
                } catch {
                    DispatchQueue.main.async { onPickFileData(nil, error) }
                }
            }
        }
    }
    #endif
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

    /// The collapsible field group a row belongs to. Phone/email/url/address
    /// rows that carry an "old" label are hidden behind a per-group "more…"
    /// disclosure; every other row leaves this `nil` and is always shown.
    enum FieldGroup: Hashable {
        case phone
        case email
        case url
        case address
    }

    let label: String
    let kind: Kind
    /// Which collapsible group this row participates in, if any.
    var group: FieldGroup?
    /// True when this row's raw label is the user's "old" custom label, so it
    /// hides behind its group's "more…" disclosure.
    var isOld: Bool = false
    /// Position of this row within its field group, assigned in `infoRows(for:)`.
    /// Disambiguates the id of genuinely-duplicate values (e.g. two phones both
    /// labeled "other" with the same number — degenerate but real) so `ForEach`
    /// never sees colliding ids.
    var groupOccurrence: Int = 0

    /// Content-derived stable identity. A per-render `UUID()` would re-mint each
    /// time `infoRows(for:)` runs, so the "old"-row reveal `withAnimation` would
    /// see every row as new and re-lay-out the whole info card instead of sliding
    /// in only the revealed rows. Keying on the row's content (plus group/isOld
    /// and the per-group occurrence index for duplicate values) keeps identity
    /// stable across renders AND unique, so the animation touches only the rows
    /// that actually appear/disappear.
    var id: String {
        let kindKey: String
        switch kind {
        case .text(let value, _, _): kindKey = "text|\(value)"
        case .phone(let number): kindKey = "phone|\(number)"
        case .email(let address): kindKey = "email|\(address)"
        case .url(let urlString): kindKey = "url|\(urlString)"
        case .address(let address): kindKey = "address|\(String(describing: address))"
        case .date(_, let formatted): kindKey = "date|\(formatted)"
        case .contactLink(let displayName, let contactID): kindKey = "contactLink|\(displayName)|\(String(describing: contactID))"
        case .backReference(let displayName, let descriptor, let contactID): kindKey = "backRef|\(displayName)|\(descriptor)|\(String(describing: contactID))"
        }
        let groupKey = group.map { String(describing: $0) } ?? "none"
        return "\(groupKey)|\(isOld ? "old" : "cur")|\(groupOccurrence)|\(label)|\(kindKey)"
    }

    static func text(label: String, value: String, monospaced: Bool = false, valueColor: Color? = nil) -> InfoRowData {
        InfoRowData(label: label, kind: .text(value: value, monospaced: monospaced, valueColor: valueColor))
    }
    static func phone(label: String, number: String, isOld: Bool = false) -> InfoRowData {
        InfoRowData(label: label, kind: .phone(number: number), group: .phone, isOld: isOld)
    }
    static func email(label: String, address: String, isOld: Bool = false) -> InfoRowData {
        InfoRowData(label: label, kind: .email(address: address), group: .email, isOld: isOld)
    }
    static func url(label: String, urlString: String, isOld: Bool = false) -> InfoRowData {
        InfoRowData(label: label, kind: .url(urlString: urlString), group: .url, isOld: isOld)
    }
    static func address(label: String, address: PostalAddress, isOld: Bool = false) -> InfoRowData {
        InfoRowData(label: label, kind: .address(address), group: .address, isOld: isOld)
    }
    static func date(label: String, components: DateComponents, formatted: String) -> InfoRowData {
        InfoRowData(label: label, kind: .date(components: components, formatted: formatted))
    }
    static func contactLink(label: String, displayName: String, contactID: ContactID) -> InfoRowData {
        InfoRowData(label: label, kind: .contactLink(displayName: displayName, contactID: contactID))
    }
    static func backReference(displayName: String, descriptor: String, contactID: ContactID) -> InfoRowData {
        // No top-line label — the back-ref row's primary text is the contact
        // name, with the descriptor as a small caption.
        InfoRowData(label: "", kind: .backReference(displayName: displayName, descriptor: descriptor, contactID: contactID))
    }
}

private struct InfoRow: View {
    let data: InfoRowData
    /// Called when the user CALLS, EMAILS, or COPIES this row's value — a genuine
    /// "interaction" with the contact. Supplied by `ContactDetailView` as
    /// `{ Task { try? await repository.stampInteracted(id) } }`; defaults to a
    /// no-op so non-phone/email rows (and call sites that don't care) stay dumb.
    /// Only the `.phone` / `.email` cases invoke it — `.url` and `.date` taps
    /// aren't interactions (per product).
    var onInteract: () -> Void = {}
    // Bridge to the outer UIKit nav controller (iPhone shell) for contact-link
    // and back-reference rows — pushes a fresh ContactDetailView via
    // SceneDelegate. Defaults to a no-op closure (see `ReferenceNavigation.swift`).
    @Environment(\.pushContactReference) private var pushContactReference

    var body: some View {
        switch data.kind {
        case .text(let value, let monospaced, let valueColor):
            labeledValue(label: data.label, value: value, monospaced: monospaced, valueColor: valueColor)
        case .phone(let number):
            // Phone taps call AND stamp lastInteracted; the row also offers a
            // platform-specific Copy affordance that copies the raw number.
            // Display the OS-formatted number (dashes/parens) while keeping the
            // raw digits for dialing and Copy.
            TappableInfoRow(label: data.label, value: number,
                            displayValue: PhoneNumberDisplayFormatter.shared.string(from: number),
                            url: phoneURL(number),
                            stampsInteraction: true, allowsCopy: true, onInteract: onInteract)
        case .email(let address):
            TappableInfoRow(label: data.label, value: address, url: URL(string: "mailto:\(address)"),
                            stampsInteraction: true, allowsCopy: true, onInteract: onInteract)
        case .url(let urlString):
            // URL / date taps just open their target — not interactions, no copy.
            // Present (and open) the https-normalized form; the stored value on
            // the contact is left untouched.
            let displayURL = httpsDisplayURLString(urlString)
            TappableInfoRow(label: data.label, value: displayURL, url: URL(string: displayURL),
                            stampsInteraction: false, allowsCopy: false)
        case .address(let address):
            AddressRow(label: data.label, address: address)
        case .date(let components, let formatted):
            TappableInfoRow(label: data.label, value: formatted, url: calendarURL(for: components),
                            stampsInteraction: false, allowsCopy: false)
        case .contactLink(let displayName, let contactID):
            contactLinkRow(label: data.label, displayName: displayName, contactID: contactID)
        case .backReference(let displayName, let descriptor, let contactID):
            backReferenceRow(displayName: displayName, descriptor: descriptor, contactID: contactID)
        }
    }

    @ViewBuilder
    private func backReferenceRow(displayName: String, descriptor: String, contactID: ContactID) -> some View {
        // Inverse-relation row: contact name is primary tinted (the tappable
        // target); the descriptor reads "their <label>" in small caption so the
        // direction is unambiguous.
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
        // Match the tappable-row visual: label above, tinted value, whole row
        // tappable. Push goes through the env-injected closure so SwiftUI rows on
        // a UIKit nav stack still navigate.
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

    /// Display-only https normalization for URL rows (per product): an
    /// `http://` value reads and opens as `https://`, and a scheme-less value
    /// (e.g. "example.com") gets an `https://` prefix. Non-web schemes
    /// (mailto:, ftp:, …) pass through unchanged, and the stored contact
    /// value is never rewritten.
    private func httpsDisplayURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased().hasPrefix("http://") {
            return "https://" + trimmed.dropFirst("http://".count)
        }
        // Any other explicit scheme (https:, mailto:, ftp:, …) is respected.
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            return trimmed
        }
        // Protocol-relative ("//example.com") just needs the scheme itself.
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        return "https://" + trimmed
    }

    private func phoneURL(_ raw: String) -> URL? {
        // tel: requires digits only (plus '+'); strip everything else.
        let allowed = Set("+0123456789")
        let cleaned = raw.filter { allowed.contains($0) }
        guard !cleaned.isEmpty else { return nil }
        return URL(string: "tel:\(cleaned)")
    }

    private func calendarURL(for components: DateComponents) -> URL? {
        // Calendar's calshow: scheme takes seconds since 2001-01-01. Birthdays
        // often lack a year; land Calendar on this year's occurrence so the user
        // sees the next/most recent one rather than year 1.
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

/// A tappable info value (phone / email / url / date). The whole row is the hit
/// target and the value reads in tint, matching Apple's Contacts. Two
/// caller-gated behaviors layer on top:
///
/// - `stampsInteraction` (phone / email): tapping the row STAMPS lastInteracted
///   before opening the URL, so a call/email registers as an interaction. URL /
///   date rows leave this off — opening a website or a calendar date isn't an
///   interaction with the person (per product).
/// - `allowsCopy` (phone / email): adds a "Copy" affordance that copies the RAW
///   value (the number / address, never the label) and also stamps interacted.
///   Platform-specific:
///     • Mac Catalyst — a trailing Copy button revealed ON HOVER (Apple's Mac
///       Contacts shows row actions on hover).
///     • iOS / iPadOS — a LEADING swipe action (right-swipe) labeled "Copy", the
///       native list idiom (valid here since the rows live in the detail `List`).
///
/// Stamp + copy run on the MainActor via the injected `onInteract` closure
/// (`ContactDetailView` supplies the fire-and-forget stamp); copying is a pure
/// `UIPasteboard` write that never blocks.
private struct TappableInfoRow: View {
    let label: String
    let value: String
    /// The string SHOWN to the user, when it differs from `value`. Phone rows
    /// pass the OS-formatted number here while keeping the raw digits in `value`
    /// so dialing and Copy still use the unformatted number. `nil` = show `value`.
    var displayValue: String? = nil
    let url: URL?
    let stampsInteraction: Bool
    let allowsCopy: Bool
    var onInteract: () -> Void = {}

    /// What the tinted/selectable label renders — the formatted form if supplied.
    private var shownValue: String { displayValue ?? value }

    @Environment(\.openURL) private var openURL
    // Drives the Catalyst hover-reveal of the trailing Copy button. Unused on
    // iOS (the swipe action handles copy there) but harmless — `.onHover` only
    // fires where a pointer exists.
    @State private var isHovering = false

    var body: some View {
        if url != nil {
            tappableContent
                .copyAffordances(value: value, allowsCopy: allowsCopy, onCopy: copy)
                // Long-press (iOS) / right-click (Catalyst) Copy on EVERY tappable
                // row — phone, email, url, and date alike — since the tap is
                // consumed by call/email/open and the value can't be text-selected
                // out of a Button. Routes through `copy()`, so phone/email still
                // stamp lastInteracted (their `onInteract` is wired); url/date have
                // a no-op `onInteract`, so those just copy. This is the uniform
                // long-press path; the hover/swipe affordances above stay as the
                // platform-native quick copy for phone/email.
                .contextMenu {
                    Button {
                        copy()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        } else {
            // No URL to open: fall back to a plain, selectable label/value with
            // no tap or stamp. Already copyable via text selection.
            labeledValue
        }
    }

    /// The tinted, whole-row-tappable content. On phone/email the tap routes
    /// through `onInteract` (stamp) then `openURL`; otherwise it just opens the
    /// URL. A `Button` (not `Link`) so the stamp can run before the open while
    /// keeping the identical tinted-value look.
    @ViewBuilder
    private var tappableContent: some View {
        Button {
            if stampsInteraction { onInteract() }
            if let url { openURL(url) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(shownValue)
                        .foregroundStyle(.tint)
                }
                #if targetEnvironment(macCatalyst)
                if allowsCopy {
                    Spacer(minLength: 8)
                    // Trailing Copy button, revealed on hover. `opacity` (not a
                    // conditional insert) keeps the row height stable as it fades
                    // in/out. It lives INSIDE the outer Button's label, but as its
                    // own `.borderless` Button claims a separate hit region: a tap
                    // on the Copy glyph copies + stamps and does NOT propagate to
                    // the outer row-open Button.
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityLabel("Copy")
                }
                #endif
            }
        }
        .buttonStyle(.plain)
        #if targetEnvironment(macCatalyst)
        .onHover { hovering in isHovering = hovering }
        #endif
    }

    @ViewBuilder
    private var labeledValue: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(shownValue)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    /// Copy the RAW value to the system pasteboard and stamp the interaction.
    private func copy() {
        UIPasteboard.general.string = value
        onInteract()
    }
}

private extension View {
    /// Attach the iOS leading-swipe "Copy" action. A no-op on Catalyst (which
    /// uses the in-row hover button) and when the row doesn't allow copy. A
    /// modifier so `TappableInfoRow.body` reads cleanly and the `#if` fork lives
    /// in one place.
    @ViewBuilder
    func copyAffordances(value: String, allowsCopy: Bool, onCopy: @escaping () -> Void) -> some View {
        #if targetEnvironment(macCatalyst)
        // Catalyst copy is the in-row hover button; no swipe action here.
        self
        #else
        if allowsCopy {
            self.swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .tint(.blue)
            }
        } else {
            self
        }
        #endif
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
        // Tapping the row opens Maps, so long-press / right-click is the way to
        // copy the address text (the formatted mailing string, matching what's
        // shown).
        .copyableText(formatted)
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

/// One editable custom-field row for contact-edit mode: read-only name label
/// above an editable value field. Commits via `onCommit` when the field loses
/// focus or the user submits — only if the value actually changed.
private struct EditableSidecarFieldRow: View {
    let name: String
    let initialValue: String
    /// Multi-line fields let Return insert newlines; single-line fields submit on
    /// Return and never contain a `\n` (though they may visually wrap).
    let isMultiline: Bool
    let onCommit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(name: String, initialValue: String, isMultiline: Bool, onCommit: @escaping (String) -> Void) {
        self.name = name
        self.initialValue = initialValue
        self.isMultiline = isMultiline
        self.onCommit = onCommit
        _draft = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption).foregroundStyle(.secondary)
            Group {
                if isMultiline {
                    // Return inserts a newline; grows vertically.
                    TextField("Value", text: $draft, axis: .vertical)
                } else {
                    // Single line: Return submits (commits); strip any pasted \n.
                    TextField("Value", text: $draft)
                        .onChange(of: draft) { _, new in
                            if new.contains("\n") { draft = new.replacingOccurrences(of: "\n", with: " ") }
                        }
                }
            }
            .focused($focused)
            .onSubmit(commit)
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != initialValue else { return }
        onCommit(trimmed)
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
