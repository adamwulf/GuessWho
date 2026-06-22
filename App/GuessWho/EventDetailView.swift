import SwiftUI
import GuessWhoSync

struct EventDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let eventUUID: String

    @State private var event: Event?
    @State private var links: [ContactLink] = []
    @State private var uuidToContact: [String: Contact] = [:]
    @State private var notes: [ContactNote] = []
    @State private var tags: [EventTag] = []

    @State private var showingPicker = false
    @State private var showingEditSheet = false
    @State private var showingUnlinkConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var showingLinkSheet = false

    @State private var newNoteText: String = ""
    @State private var editingNoteID: UUID?
    @State private var editingNoteDraft: String = ""

    @State private var newTagText: String = ""

    var body: some View {
        Form {
            if let event {
                detailsSection(event)
                guessWhoNotesSection
                tagsSection
                linkedContactsSection
                linkActionsSection(event)
            } else {
                Section { Text("(Unknown event)") }
            }
        }
        .navigationTitle(event?.title.isEmpty == false ? event!.title : "Event")
        .task { reload() }
        .toolbar {
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
        .sheet(isPresented: $showingLinkSheet) {
            EventLinkSheet(mode: .adopt(eventUUID: eventUUID, onAdopted: {
                reload()
            }))
        }
        .confirmationDialog(
            "Unlink from Calendar?",
            isPresented: $showingUnlinkConfirm,
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) { unlink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The event stays in Calendar. GuessWho will keep your notes and tags.")
        }
        .confirmationDialog(
            "Remove from GuessWho? (Won't delete from Calendar.)",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { delete() }
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
        let endpoint = SidecarKey(kind: .event, id: eventUUID)
        let other = SyncService.otherEndpoint(of: link, from: endpoint)
        let contact = uuidToContact[other.id]

        if let contact {
            NavigationLink(value: ContactReference(localID: contact.localID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                    if !link.note.isEmpty {
                        Text(link.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
    private func linkActionsSection(_ event: Event) -> some View {
        Section {
            if event.isLinked {
                Button(role: .destructive) {
                    showingUnlinkConfirm = true
                } label: {
                    Label("Unlink from Calendar", systemImage: "calendar.badge.minus")
                }
            } else {
                Button {
                    showingLinkSheet = true
                } label: {
                    Label("Link to a calendar event", systemImage: "calendar.badge.plus")
                }
                .disabled(service.eventsAuthorization != .authorized)
            }
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete event", systemImage: "trash")
            }
        }
    }

    private func reload() {
        service.refreshEvent(uuid: eventUUID)
        event = service.event(uuid: eventUUID)
        links = service.contactLinks(forEventUUID: eventUUID)
        notes = service.eventNotes(forEventUUID: eventUUID)
        tags = service.eventTags(forEventUUID: eventUUID)
        var map: [String: Contact] = [:]
        for contact in service.fetchAll() {
            if let uuid = service.guessWhoUUID(in: contact) {
                map[uuid] = contact
            }
        }
        uuidToContact = map
    }

    private func addLink(to contact: Contact, note: String) {
        guard let uuid = service.guessWhoUUID(in: contact) else { return }
        do {
            _ = try service.addContactEventLink(contactUUID: uuid, eventUUID: eventUUID, note: note)
        } catch {
            service.recordError("add contact-event link failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func remove(linkID: UUID) {
        do {
            try service.removeLink(id: linkID)
        } catch {
            service.recordError("remove link failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func save(_ edited: Event) {
        do {
            try service.updateEvent(
                uuid: eventUUID,
                title: edited.title,
                startDate: edited.startDate,
                endDate: edited.endDate,
                isAllDay: edited.isAllDay,
                location: edited.location
            )
        } catch {
            service.recordError("update event failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func unlink() {
        do {
            try service.unlinkEvent(uuid: eventUUID)
        } catch {
            service.recordError("unlink event failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func delete() {
        do {
            try service.deleteEvent(uuid: eventUUID)
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
            _ = try service.addEventNote(body: trimmed, forEventUUID: eventUUID)
            newNoteText = ""
        } catch {
            service.recordError("add event note failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func commitEdit(_ id: UUID) {
        let trimmed = editingNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingNoteID = nil
            editingNoteDraft = ""
            return
        }
        do {
            try service.editEventNote(id: id, newBody: trimmed, forEventUUID: eventUUID)
        } catch {
            service.recordError("edit event note failed: \(error.localizedDescription)")
        }
        editingNoteID = nil
        editingNoteDraft = ""
        reload()
    }

    private func deleteNote(_ id: UUID) {
        do {
            try service.deleteEventNote(id: id, forEventUUID: eventUUID)
        } catch {
            service.recordError("delete event note failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func commitNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try service.addEventTag(text: trimmed, forEventUUID: eventUUID)
            newTagText = ""
        } catch {
            service.recordError("add event tag failed: \(error.localizedDescription)")
        }
        reload()
    }

    private func deleteTag(_ id: UUID) {
        do {
            try service.deleteEventTag(id: id, forEventUUID: eventUUID)
        } catch {
            service.recordError("delete event tag failed: \(error.localizedDescription)")
        }
        reload()
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
            .task { contacts = service.fetchAll() }
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
