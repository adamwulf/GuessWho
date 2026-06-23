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
    @State private var notes: [ContactNote] = []
    @State private var tags: [EventTag] = []
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
                addLink(to: contact, note: note)
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            if let event {
                EventEditSheet(event: event) { updated in
                    save(updated)
                }
            }
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
                    Text("Calendar Notes").font(.caption).foregroundStyle(.secondary)
                    Text(notes)
                }
            }
        }
    }

    @ViewBuilder
    private var guessWhoNotesSection: some View {
        Section("Notes") {
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
        for contact in await service.fetchAll() {
            if let uuid = service.guessWhoUUID(in: contact) {
                map[uuid] = contact
            }
        }
        uuidToContact = map
        hasLoadedOnce = true
    }

    private func addLink(to contact: Contact, note: String) {
        guard let uuid = service.guessWhoUUID(in: contact) else { return }
        do {
            _ = try service.addContactEventLink(contactUUID: uuid, eventUUID: resolvedUUID, note: note)
        } catch {
            service.recordError("add contact-event link failed: \(error.localizedDescription)")
        }
        Task { await reload() }
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

    let onPick: (Contact, String) -> Void

    @State private var query: String = ""
    @State private var contacts: [Contact] = []
    @State private var selection: Contact?
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let selection {
                    Form {
                        Section("Contact") {
                            HStack {
                                Text(selection.displayName)
                                Spacer()
                                Button("Change") { self.selection = nil }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Section("Note") {
                            TextField("Optional note", text: $note, axis: .vertical)
                        }
                    }
                } else {
                    List(filteredContacts, id: \.localID) { contact in
                        Button {
                            selection = contact
                        } label: {
                            VStack(alignment: .leading) {
                                Text(contact.displayName)
                                if service.guessWhoUUID(in: contact) == nil {
                                    Text("Not yet reconciled — open the contact first")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(service.guessWhoUUID(in: contact) == nil)
                    }
                    .searchable(text: $query, prompt: "Search contacts")
                }
            }
            .navigationTitle(selection == nil ? "Pick Contact" : "Add Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let selection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            onPick(selection, note.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        }
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
