import SwiftUI
import GuessWhoSync

struct EventDetailView: View {
    @Environment(SyncService.self) private var service

    let externalID: String

    @State private var event: Event?
    @State private var links: [ContactLink] = []
    @State private var uuidToContact: [String: Contact] = [:]
    @State private var showingPicker = false

    var body: some View {
        Form {
            if let event {
                detailsSection(event)
            } else {
                Section { Text("(Unknown event)") }
            }
            linkedContactsSection
        }
        .navigationTitle(event?.title.isEmpty == false ? event!.title : "Event")
        .task { reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPicker = true
                } label: {
                    Label("Add Contact", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(event == nil)
            }
        }
        .sheet(isPresented: $showingPicker) {
            ContactPickerSheet { contact, note in
                addLink(to: contact, note: note)
            }
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
            if let notes = event.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    Text(notes)
                }
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
        let endpoint = SidecarKey(kind: .event, id: externalID)
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

    private func reload() {
        event = service.event(externalID: externalID)
        links = service.contactLinks(forEventID: externalID)
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
            _ = try service.addContactEventLink(contactUUID: uuid, eventID: externalID, note: note)
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
