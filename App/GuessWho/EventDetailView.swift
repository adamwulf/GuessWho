import SwiftUI
import GuessWhoSync

struct EventDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(FavoritesListStore.self) private var favoritesStore
    @Environment(\.dismiss) private var dismiss
    // Bridge to the outer UIKit nav controller (iPhone shell) so an
    // attendee row pushes a fresh ContactDetailView. See
    // `ReferenceNavigation.swift` for the env-closure defaults
    // (no-op for Catalyst / SwiftUI previews).
    @Environment(\.pushContactReference) private var pushContactReference

    /// Optional EventKit identifier carried so the detail view can adopt
    /// (mint or look up) the sidecar for an ephemeral EventKit row whose
    /// `eventUUID` is `Event.stableID(forEventKitID:)`, not a real
    /// sidecar UUID.
    private let eventKitID: String?

    /// The sidecar UUID currently being read/written. Starts as the UUID
    /// handed in by the navigation push and is swapped to the real
    /// sidecar UUID after adoption — every internal use (reads, writes,
    /// sub-sheet passes) targets `resolvedUUID`.
    @State private var resolvedUUID: String
    /// Guards `reload()` against concurrent adoption attempts. Without it,
    /// fast successive reloads (mutation immediately after appearance)
    /// could each see `event == nil` and both call `linkEvent`, minting
    /// duplicate sidecars.
    @State private var adoptionInFlight: Bool = false

    @State private var event: Event?
    @State private var links: [ContactLink] = []
    @State private var uuidToContact: [String: Contact] = [:]
    /// Lowercased email → contact lookup, populated alongside `uuidToContact`
    /// from the same `service.fetchAll()` pass. Used by the invitees section
    /// to decide row-tap behavior (push existing vs. open new-contact sheet).
    /// First contact wins on duplicates — the picker can still surface the
    /// other later.
    @State private var emailToContact: [String: Contact] = [:]
    @State private var notes: [ContactNote] = []
    @State private var tags: [EventTag] = []
    /// Drives the "Add Contact" sheet from the invitees section. Non-nil
    /// holds the pre-filled `Contact` seed handed to `ContactEditView`.
    @State private var addingContactSeed: AddingContactSeed?

    private struct AddingContactSeed: Identifiable {
        // Per-presentation UUID so SwiftUI re-presents the sheet when the
        // user picks a second unmatched invitee — both seeds have an empty
        // `localID`, so falling back to that would collide and suppress
        // the second presentation.
        let id: UUID = UUID()
        let contact: Contact
    }
    /// `false` until the first `reload()` finishes. The body uses it to
    /// distinguish "still loading" from "really missing" so the
    /// "(Unknown event)" fallback doesn't flash during the async
    /// `fetchAll()` round-trip inside `reload()`.
    @State private var hasLoadedOnce: Bool = false

    @State private var showingPicker = false
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirm = false

    @State private var newNoteText: String = ""
    @State private var editingNoteID: UUID?
    @State private var editingNoteDraft: String = ""

    @State private var newTagText: String = ""

    init(eventUUID: String, eventKitID: String? = nil) {
        self.eventKitID = eventKitID
        _resolvedUUID = State(initialValue: eventUUID.lowercased())
    }

    var body: some View {
        Form {
            if let event {
                detailsSection(event)
                guessWhoNotesSection
                tagsSection
                inviteesSection(event)
                linkedContactsSection
                deleteActionSection
            } else if hasLoadedOnce {
                Section { Text("(Unknown event)") }
            } else {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(event?.title.isEmpty == false ? event!.title : "Event")
        .task { await reload() }
        .toolbar {
            // Star sits BEFORE the existing Menu so the toolbar reads
            // star, ellipsis. Disabled until the event resolves AND the
            // sidecar UUID is real (post-adoption) — favoriting a
            // synthetic stable-id would point at a sidecar that doesn't
            // exist, and the user can adopt one tap away via the Menu.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isEventFavorited ? "star.fill" : "star")
                }
                .disabled(!canFavoriteEvent)
                .accessibilityLabel(isEventFavorited ? "Unfavorite" : "Favorite")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingEditSheet = true
                    } label: {
                        Label("Edit Event", systemImage: "pencil")
                    }
                    .disabled(event == nil)

                    Button {
                        showingPicker = true
                    } label: {
                        Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(event == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            ContactPickerSheet { contact, note in
                await addLink(to: contact, note: note)
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            if let event {
                EventEditSheet(event: event) { updated in
                    save(updated)
                }
            }
        }
        .sheet(item: $addingContactSeed) { seed in
            // ContactEditView treats an empty `localID` as a brand-new
            // record: `CNContactStoreAdapter.save` falls through to its
            // `add(...)` branch when the unifiedContact lookup misses, so
            // the editor's existing Save path mints a fresh CNContact
            // pre-populated with the attendee's name + email. After save
            // we reload so the invitees section can re-match against the
            // newly-created contact.
            ContactEditView(
                newContactSeed: seed.contact,
                onDone: { Task { await reload() } }
            )
        }
        .confirmationDialog(
            "Delete this event?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func detailsSection(_ event: Event) -> some View {
        Section("Details") {
            HStack {
                Text("Starts").foregroundStyle(.secondary)
                Spacer()
                Text(event.startDate, style: .date)
                if !event.isAllDay {
                    Text(event.startDate, style: .time)
                }
            }
            HStack {
                Text("Ends").foregroundStyle(.secondary)
                Spacer()
                Text(event.endDate, style: .date)
                if !event.isAllDay {
                    Text(event.endDate, style: .time)
                }
            }
            if let location = event.location, !location.isEmpty {
                HStack {
                    Text("Location").foregroundStyle(.secondary)
                    Spacer()
                    Text(location)
                }
            }
            if let notes = event.eventKitNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    Text(notes)
                }
            }
        }
    }

    @ViewBuilder
    private var guessWhoNotesSection: some View {
        Section("Additional Notes") {
            ForEach(notes, id: \.id) { note in
                noteRow(note)
            }
            .onDelete { offsets in
                let ids = offsets.map { notes[$0].id }
                for id in ids { deleteNote(id) }
            }
            TextField("Add a note", text: $newNoteText, axis: .vertical)
                .submitLabel(.done)
                .onSubmit { commitNewNote() }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: ContactNote) -> some View {
        if editingNoteID == note.id {
            HStack {
                TextField("", text: $editingNoteDraft, axis: .vertical)
                Button("Save") {
                    commitEdit(note.id)
                }
                .buttonStyle(.borderless)
            }
        } else {
            Text(note.body)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingNoteID = note.id
                    editingNoteDraft = note.body
                }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        Section("Tags") {
            if tags.isEmpty {
                Text("No tags").foregroundStyle(.secondary)
            } else {
                ForEach(tags, id: \.id) { tag in
                    Text(tag.text)
                }
                .onDelete { offsets in
                    let ids = offsets.map { tags[$0].id }
                    for id in ids { deleteTag(id) }
                }
            }
            HStack {
                TextField("Add a tag", text: $newTagText)
                Button("Add") {
                    commitNewTag()
                }
                .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Invitees mirrored from `EKEvent.attendees`. Each row resolves to one
    /// of three states based on email match against the user's contacts:
    /// matched → tap pushes the contact detail; unmatched (with email) →
    /// tap opens a pre-filled new-contact editor; no email → display only.
    /// Hidden when the event has no attendees, so manual (sidecar-only)
    /// events show no empty section.
    @ViewBuilder
    private func inviteesSection(_ event: Event) -> some View {
        if !event.attendees.isEmpty {
            Section("Invitees") {
                ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, attendee in
                    inviteeRow(attendee)
                }
            }
        }
    }

    @ViewBuilder
    private func inviteeRow(_ attendee: EventAttendee) -> some View {
        if let email = attendee.email, let contact = emailToContact[email] {
            Button {
                pushContactReference(ContactReference(localID: contact.localID))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                    if !email.isEmpty {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else if let email = attendee.email {
            Button {
                addingContactSeed = AddingContactSeed(contact: contactSeed(from: attendee, email: email))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attendee.name.isEmpty ? email : attendee.name)
                        if !email.isEmpty, !attendee.name.isEmpty {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.plus")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            // No email to match on — render as plain text. The user can't
            // do anything with this row, but hiding it would lose a real
            // attendee the calendar event has.
            Text(attendee.name.isEmpty ? "(Unknown invitee)" : attendee.name)
                .foregroundStyle(.secondary)
        }
    }

    /// Build the seed `Contact` handed to `ContactEditView` for an
    /// unmatched attendee. `localID` is empty so the adapter's save path
    /// takes the brand-new-contact branch. The display name is run
    /// through Foundation's `PersonNameComponents` parse strategy so
    /// prefix/given/middle/family/suffix all land in the right fields
    /// (e.g. "Dr. Jane Q. Doe Jr." splits correctly). When the attendee
    /// name is missing or is just the email itself, we leave the name
    /// fields empty rather than letting the parser shove the email into
    /// `givenName`.
    private func contactSeed(from attendee: EventAttendee, email: String) -> Contact {
        let trimmed = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: PersonNameComponents?
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(email) == .orderedSame {
            parsed = nil
        } else {
            parsed = try? PersonNameComponents(trimmed, strategy: .name)
        }
        return Contact(
            localID: "",
            namePrefix: parsed?.namePrefix ?? "",
            givenName: parsed?.givenName ?? "",
            middleName: parsed?.middleName ?? "",
            familyName: parsed?.familyName ?? "",
            nameSuffix: parsed?.nameSuffix ?? "",
            emailAddresses: [LabeledValue(label: "", value: email)]
        )
    }

    @ViewBuilder
    private var linkedContactsSection: some View {
        Section("Linked Contacts") {
            if links.isEmpty {
                Text("No linked contacts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(links, id: \.id) { link in
                    linkedContactRow(link)
                }
                .onDelete { offsets in
                    let ids = offsets.map { links[$0].id }
                    for id in ids { remove(linkID: id) }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedContactRow(_ link: ContactLink) -> some View {
        let endpoint = SidecarKey(kind: .event, id: resolvedUUID)
        let other = SyncService.otherEndpoint(of: link, from: endpoint)
        let contact = uuidToContact[other.id]

        if let contact {
            Button {
                pushContactReference(ContactReference(localID: contact.localID))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                    if !link.note.isEmpty {
                        Text(link.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("(Unknown contact)")
                    .foregroundStyle(.secondary)
                if !link.note.isEmpty {
                    Text(link.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var deleteActionSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete event", systemImage: "trash")
            }
        }
    }

    private var canFavoriteEvent: Bool {
        // Sidecar must already exist for `resolvedUUID` — the synthetic
        // `Event.stableID(forEventKitID:)` an unadopted EventKit row carries
        // has no sidecar, so `service.event(uuid:)` returns nil for it.
        // After adoption, `resolvedUUID` is swapped to the real UUID and
        // this becomes true.
        event != nil && service.event(uuid: resolvedUUID) != nil
    }

    private var isEventFavorited: Bool {
        // Gate symmetric with `toggleFavorite` and `canFavoriteEvent` —
        // a synthetic stable-id can never hold a real favorite, but
        // querying the store for one would silently report "not
        // favorited" without making the dependency explicit.
        guard canFavoriteEvent else { return false }
        return favoritesStore.isFavorite(kind: .event, id: resolvedUUID)
    }

    private func toggleFavorite() {
        guard canFavoriteEvent else { return }
        favoritesStore.toggle(kind: .event, id: resolvedUUID)
    }

    private func reload() async {
        // Adopt-on-load: if the incoming UUID is the synthetic
        // `Event.stableID(forEventKitID:)` for an ephemeral EventKit row
        // (no sidecar exists at that key) AND we were handed an
        // `eventKitID` hint, mint or look up the real sidecar UUID first
        // so every read/write below targets it. Guarded by
        // `adoptionInFlight` so concurrent reloads can't double-mint.
        if service.event(uuid: resolvedUUID) == nil,
           let ekid = eventKitID,
           !adoptionInFlight
        {
            adoptionInFlight = true
            defer { adoptionInFlight = false }
            if let existing = service.eventUUID(forEventKitID: ekid) {
                resolvedUUID = existing.uuidString.lowercased()
            } else {
                do {
                    let minted = try service.linkEvent(toEventKitID: ekid)
                    resolvedUUID = minted.uuidString.lowercased()
                } catch {
                    service.recordError("adopt event failed: \(error.localizedDescription)")
                }
            }
        }
        service.refreshEvent(uuid: resolvedUUID)
        event = service.event(uuid: resolvedUUID)
        links = service.contactLinks(forEventUUID: resolvedUUID)
        notes = service.eventNotes(forEventUUID: resolvedUUID)
        tags = service.eventTags(forEventUUID: resolvedUUID)
        var map: [String: Contact] = [:]
        var byEmail: [String: Contact] = [:]
        for contact in await service.fetchAll() {
            if let uuid = service.guessWhoUUID(in: contact) {
                map[uuid] = contact
            }
            for entry in contact.emailAddresses {
                let key = entry.value.lowercased()
                guard !key.isEmpty, byEmail[key] == nil else { continue }
                byEmail[key] = contact
            }
        }
        uuidToContact = map
        emailToContact = byEmail
        hasLoadedOnce = true
    }

    /// Returns `true` when the link was created (or already existed) so the
    /// picker sheet knows it's safe to dismiss. Reconcile failures return
    /// `false` and surface via `service.recordError` so the user can pick a
    /// different contact or retry without losing the sheet.
    private func addLink(to contact: Contact, note: String) async -> Bool {
        let uuid: String
        do {
            uuid = try await service.reconcileIfNeeded(contact: contact)
        } catch {
            service.recordError("reconcile contact failed: \(error.localizedDescription)")
            return false
        }
        do {
            _ = try service.addContactEventLink(contactUUID: uuid, eventUUID: resolvedUUID, note: note)
        } catch {
            service.recordError("add contact-event link failed: \(error.localizedDescription)")
            return false
        }
        await reload()
        return true
    }

    private func remove(linkID: UUID) {
        do {
            try service.removeLink(id: linkID)
        } catch {
            service.recordError("remove link failed: \(error.localizedDescription)")
        }
        Task { await reload() }
    }

    private func save(_ edited: Event) {
        do {
            try service.updateEvent(
                uuid: resolvedUUID,
                title: edited.title,
                startDate: edited.startDate,
                endDate: edited.endDate,
                isAllDay: edited.isAllDay,
                location: edited.location
            )
        } catch {
            service.recordError("update event failed: \(error.localizedDescription)")
        }
        Task { await reload() }
    }

    private func delete() {
        do {
            try service.deleteEvent(uuid: resolvedUUID)
            dismiss()
        } catch {
            service.recordError("delete event failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Notes/Tags helpers

    private func commitNewNote() {
        let trimmed = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try service.addEventNote(body: trimmed, forEventUUID: resolvedUUID)
            newNoteText = ""
        } catch {
            service.recordError("add event note failed: \(error.localizedDescription)")
        }
        Task { await reload() }
    }

    private func commitEdit(_ id: UUID) {
        let trimmed = editingNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingNoteID = nil
            editingNoteDraft = ""
            return
        }
        do {
            try service.editEventNote(id: id, newBody: trimmed, forEventUUID: resolvedUUID)
        } catch {
            service.recordError("edit event note failed: \(error.localizedDescription)")
        }
        editingNoteID = nil
        editingNoteDraft = ""
        Task { await reload() }
    }

    private func deleteNote(_ id: UUID) {
        do {
            try service.deleteEventNote(id: id, forEventUUID: resolvedUUID)
        } catch {
            service.recordError("delete event note failed: \(error.localizedDescription)")
        }
        Task { await reload() }
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try service.addEventTag(text: trimmed, forEventUUID: resolvedUUID)
            newTagText = ""
        } catch {
            service.recordError("add event tag failed: \(error.localizedDescription)")
        }
        Task { await reload() }
    }

    private func deleteTag(_ id: UUID) {
        do {
            try service.deleteEventTag(id: id, forEventUUID: resolvedUUID)
        } catch {
            service.recordError("delete event tag failed: \(error.localizedDescription)")
        }
        Task { await reload() }
    }
}

private struct EventEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initial: Event
    let onSave: (Event) -> Void

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isAllDay: Bool
    @State private var location: String

    init(event: Event, onSave: @escaping (Event) -> Void) {
        self.initial = event
        self.onSave = onSave
        _title = State(initialValue: event.title)
        _startDate = State(initialValue: event.startDate)
        _endDate = State(initialValue: event.endDate)
        _isAllDay = State(initialValue: event.isAllDay)
        _location = State(initialValue: event.location ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("When") {
                    Toggle("All-day", isOn: $isAllDay)
                    DatePicker(
                        "Starts",
                        selection: $startDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "Ends",
                        selection: $endDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                }
                Section("Location") {
                    TextField("Location", text: $location)
                }
            }
            .navigationTitle("Edit Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var edited = initial
                        edited.title = title
                        edited.startDate = startDate
                        edited.endDate = endDate
                        edited.isAllDay = isAllDay
                        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
                        edited.location = trimmedLocation.isEmpty ? nil : trimmedLocation
                        onSave(edited)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ContactPickerSheet: View {
    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss

    /// Returns `true` once the link has been created (or already existed),
    /// `false` if the underlying reconcile-then-link sequence failed. The
    /// picker surfaces its own neutral failure copy in that case — the host
    /// view is also free to surface a richer message via `recordError`.
    let onPick: (Contact, String) async -> Bool

    @State private var query: String = ""
    @State private var contacts: [Contact] = []
    @State private var selection: Contact?
    @State private var note: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let selection {
                    Form {
                        Section("Contact") {
                            HStack {
                                Text(selection.displayName)
                                Spacer()
                                Button("Change") {
                                    self.selection = nil
                                    errorMessage = nil
                                }
                                .buttonStyle(.borderless)
                                .disabled(isSubmitting)
                            }
                        }
                        Section("Note") {
                            TextField("Optional note", text: $note, axis: .vertical)
                        }
                        if let errorMessage {
                            Section {
                                Text(errorMessage)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    List(filteredContacts, id: \.localID) { contact in
                        Button {
                            selection = contact
                        } label: {
                            Text(contact.displayName)
                        }
                    }
                    .searchable(text: $query, prompt: "Search contacts")
                }
            }
            .navigationTitle(selection == nil ? "Pick Contact" : "Add Link")
            .toolbar {
                // Cancel stays enabled while submitting: if the underlying
                // CNContactStore.save hangs (iCloud contention, write lock),
                // disabling Cancel would trap the user. The unstructured
                // Task continues running after dismissal — SwiftUI state
                // mutations on the dismissed view are no-ops, so there's no
                // crash risk; any failure still surfaces via recordError.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let selection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            // Re-entry guard: a double-tap or chord can fire
                            // the Button twice before SwiftUI re-renders.
                            // Setting `isSubmitting` synchronously here (NOT
                            // inside the Task body) closes that window so a
                            // second tap can't spawn a duplicate-link Task.
                            guard !isSubmitting else { return }
                            errorMessage = nil
                            isSubmitting = true
                            Task {
                                let didLink = await onPick(
                                    selection,
                                    note.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                                if didLink {
                                    dismiss()
                                } else {
                                    errorMessage = "Couldn't add this contact. Try again or pick another."
                                }
                                isSubmitting = false
                            }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Add")
                            }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
            .task { contacts = await service.fetchAll() }
        }
    }

    private var filteredContacts: [Contact] {
        let sorted = contacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        let needle = trimmed.lowercased()
        return sorted.filter { $0.displayName.lowercased().contains(needle) }
    }
}
