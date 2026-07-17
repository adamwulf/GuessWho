import SwiftUI
import GuessWhoSync

struct EventDetailView: View {
    @Environment(SyncService.self) private var service
    @Environment(ContactsRepository.self) private var repository
    @Environment(FavoritesListStore.self) private var favoritesStore
    @Environment(\.dismiss) private var dismiss
    // Bridge to the outer UIKit nav controller (iPhone shell) so an
    // attendee row pushes a fresh ContactDetailView. See
    // `ReferenceNavigation.swift` for the env-closure defaults
    // (no-op for Catalyst / SwiftUI previews).
    @Environment(\.pushContactReference) private var pushContactReference
    @Environment(\.pushEventReference) private var pushEventReference

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
    @State private var notes: [ContactNote] = []
    @State private var tags: [EventTag] = []
    // Imported guides whose places' addresses appear in this event's location
    // text. Loaded async via SyncService, keyed on the location string.
    @State private var locationGuides: [GuideAddressMatcher.Match] = []
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
    @State private var showingOrgPicker = false
    @State private var showingEventPicker = false
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirm = false

    @State private var newNoteText: String = ""
    // The new note's user-picked date. nil = untouched, meaning "now" at
    // commit time, so a note typed slowly still stamps the save moment
    // unless the user picked a date.
    @State private var newNoteDate: Date?
    @State private var editingNoteID: UUID?
    @State private var editingNoteDraft: String = ""
    // The edited note's working date (seeded from createdAt) and its
    // edit-start snapshot; commit re-stamps only when the date moved.
    @State private var editingNoteDate: Date = .now
    @State private var editingNoteDateSnapshot: Date = .now

    @State private var newTagText: String = ""

    init(eventUUID: String, eventKitID: String? = nil) {
        self.eventKitID = eventKitID
        _resolvedUUID = State(initialValue: eventUUID.lowercased())
    }

    var body: some View {
        Form {
            if let event {
                titleHeaderSection(event)
                detailsSection(event)
                guessWhoNotesSection
                tagsSection
                inviteesSection(event)
                associatedOrganizationsSection(event)
                linkedContactsSection
                linkedOrganizationsSection
                linkedEventsSection
                deleteActionSection
                Section { linkActionsFooter }
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
        // The inline title header (below) already shows the event title, so an
        // empty nav-bar title avoids showing it twice — matching ContactDetailView,
        // whose inline header likewise carries the name while the nav title stays
        // empty. The toolbar (star + ellipsis) is unaffected.
        .navigationTitle("")
        #if !targetEnvironment(macCatalyst)
        // Inline mode so the empty title doesn't reserve large-title space above
        // the header on the pushed iPhone/iPad detail.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await reload()
            // Stamp lastViewed ONCE per open (not in reload(), which every
            // note/tag/link mutation re-runs), after adopt-on-load has swapped
            // `resolvedUUID` to the real sidecar UUID. The package no-ops when
            // no sidecar exists (e.g. a failed adoption), so a view can never
            // mint one. Mirrors ContactDetailView's on-open stampViewed.
            service.stampEventViewed(uuid: resolvedUUID)
        }
        // Recompute the guide rows whenever the event's location text changes
        // (including the initial nil → loaded transition). Empty/nil location
        // yields no rows.
        .task(id: event?.location) {
            locationGuides = await service.guides(matchingLocation: event?.location)
        }
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            ContactPickerSheet(kind: .person) { contact, note in
                await addLink(to: contact, note: note)
            }
        }
        .sheet(isPresented: $showingOrgPicker) {
            // Same link write as Add Contact — an organization is a Contact —
            // the picker just filters to organization records.
            ContactPickerSheet(kind: .organization) { contact, note in
                await addLink(to: contact, note: note)
            }
        }
        .sheet(isPresented: $showingEventPicker) {
            EventLinkSheet(
                mode: .link(onLinked: { eventUUID, note in
                    Task { await addEventLink(eventUUID: eventUUID, note: note) }
                }),
                excludingEventUUIDs: [resolvedUUID],
                excludingEventKitIDs: eventKitID.map { Set([$0]) } ?? []
            )
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

    /// Inline title header shown above the details. Mirrors ContactDetailView's
    /// header (which carries the name while the nav title stays empty) so the
    /// event title has a visible, long-pressable home: long-press (iOS) /
    /// right-click (Catalyst) offers Copy. Untitled events fall back to "Event",
    /// matching the old nav-title fallback, but the copy menu is suppressed for a
    /// blank title (see `copyableText`).
    @ViewBuilder
    private func titleHeaderSection(_ event: Event) -> some View {
        Section {
            Text(event.title.isEmpty ? "Event" : event.title)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .copyableText(event.title)
                .listRowBackground(Color.clear)
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
                        // Long-press / right-click to copy the location text.
                        .copyableText(location)
                }
                // Directly below the location, in the same section: one summary
                // row that opens the matched place's detail, where every guide
                // this place sits in is listed.
                if !locationGuides.isEmpty {
                    AddressGuidesSummaryRow(matches: locationGuides)
                }
            }
            if let notes = event.eventKitNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    Text(notes)
                        .copyableText(notes)
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
            // The date row appears once the user starts typing, defaulting
            // to now; an untouched picker stamps the actual save time.
            if !newNoteText.isEmpty {
                DatePicker(
                    "Date",
                    selection: Binding(
                        get: { newNoteDate ?? Date() },
                        set: { newNoteDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: ContactNote) -> some View {
        if editingNoteID == note.id {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("", text: $editingNoteDraft, axis: .vertical)
                    Button("Save") {
                        commitEdit(note.id)
                    }
                    .buttonStyle(.borderless)
                }
                DatePicker(
                    "Date",
                    selection: $editingNoteDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.body)
                Text(note.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingNoteID = note.id
                editingNoteDraft = note.body
                editingNoteDate = note.createdAt
                editingNoteDateSnapshot = note.createdAt
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
        if let email = attendee.email, let contactID = matchedContactID(forEmail: email),
           let contact = repository.contact(id: contactID) {
            Button {
                pushContactReference(ContactReference(id: contactID))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                        if !email.isEmpty {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
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
                .contentShape(Rectangle())
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

    /// First contact (in cache order) whose card lists `email`, addressed by
    /// `ContactID`. Resolved on demand through the repository's O(1) email
    /// index. "First wins"; the picker can still surface another match later.
    /// Returns nil when no contact lists the address (the row then offers the
    /// add-new-contact flow).
    private func matchedContactID(forEmail email: String) -> ContactID? {
        repository.contactIDs(matchingEmail: email).first
    }

    /// Build the seed `Contact` handed to `ContactEditView` for an
    /// unmatched attendee. `localID` is empty so the adapter's save path
    /// takes the brand-new-contact branch. The display name is run
    /// through Foundation's `PersonNameComponents` parse strategy so
    /// prefix/given/middle/family/suffix all land in the right fields
    /// (e.g. "Dr. Jane Q. Doe Jr." splits correctly). When the attendee
    /// name is missing or is just the email itself, we leave the name
    /// fields empty rather than letting the parser shove the email into
    /// `givenName`. If the parser throws on an unusual display name we
    /// fall back to dropping the trimmed string into `givenName`.
    private func contactSeed(from attendee: EventAttendee, email: String) -> Contact {
        let trimmed = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: PersonNameComponents?
        let givenFallback: String
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(email) == .orderedSame {
            parsed = nil
            givenFallback = ""
        } else {
            parsed = try? PersonNameComponents(trimmed, strategy: .name)
            givenFallback = parsed == nil ? trimmed : ""
        }
        return Contact(
            namePrefix: parsed?.namePrefix ?? "",
            givenName: parsed?.givenName ?? givenFallback,
            middleName: parsed?.middleName ?? "",
            familyName: parsed?.familyName ?? "",
            nameSuffix: parsed?.nameSuffix ?? "",
            emailAddresses: [LabeledValue(label: "", value: email)]
        )
    }

    /// Split the event's contact links by the linked contact's type, mirroring
    /// `ContactDetailView.connectionLinks(where:)`. Links whose contact
    /// endpoint can't be resolved (rare: unreconciled/malformed) fall into the
    /// People bucket rather than being silently dropped.
    private func linkedConnections(where type: ContactType) -> [ContactLink] {
        links.filter { link in
            guard SyncService.otherEndpoint(of: link, from: eventEndpoint).kind == .contact else {
                return false
            }
            let contact = repository.linkedContact(of: link, forEventUUID: resolvedUUID)
            return (contact?.contactType ?? .person) == type
        }
    }

    private var eventEndpoint: SidecarKey {
        SidecarKey(kind: .event, id: resolvedUUID)
    }

    private var linkedEventItems: [ContactLink] {
        links.filter {
            SyncService.otherEndpoint(of: $0, from: eventEndpoint).kind == .event
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Inferred organizations for this event, the org analog of the invitee
    /// email→contact matching above: every person on the event (attendee-
    /// matched contacts plus linked people) whose Contacts "company" field
    /// names an organization record surfaces that organization here. Same
    /// name-string inference as the contact page's "Associated Organization"
    /// section — no sidecar link is involved, so rows are read-only and just
    /// navigate to the organization. Deduped by ContactID; hidden when empty.
    @ViewBuilder
    private func associatedOrganizationsSection(_ event: Event) -> some View {
        let organizations = associatedOrganizations(event)
        if !organizations.isEmpty {
            Section("Associated Organizations") {
                ForEach(organizations, id: \.contactID) { organization in
                    Button {
                        pushContactReference(ContactReference(id: organization.contactID))
                    } label: {
                        HStack(spacing: 12) {
                            ContactAvatar(contact: organization, diameter: 28)
                            Text(organization.displayName)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func associatedOrganizations(_ event: Event) -> [Contact] {
        // The event's people: attendee-matched contacts first (section order),
        // then linked people. Organizations linked directly to the event are
        // excluded — their company field is themselves, not an association.
        var people: [Contact] = []
        for attendee in event.attendees {
            if let email = attendee.email,
               let contactID = matchedContactID(forEmail: email),
               let contact = repository.contact(id: contactID),
               contact.contactType == .person {
                people.append(contact)
            }
        }
        for link in links {
            if let contact = repository.linkedContact(of: link, forEventUUID: resolvedUUID),
               contact.contactType == .person {
                people.append(contact)
            }
        }

        var seen = Set<ContactID>()
        var organizations: [Contact] = []
        for person in people {
            guard let organization = repository.organizationContact(named: person.organizationName)
            else { continue }
            if seen.insert(organization.contactID).inserted {
                organizations.append(organization)
            }
        }
        return organizations
    }

    @ViewBuilder
    private var linkedContactsSection: some View {
        let peopleLinks = linkedConnections(where: .person)
        Section("Linked Contacts") {
            if peopleLinks.isEmpty {
                Text("No linked contacts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(peopleLinks, id: \.id) { link in
                    linkedContactRow(link)
                }
                .onDelete { offsets in
                    let ids = offsets.map { peopleLinks[$0].id }
                    for id in ids { remove(linkID: id) }
                }
            }
        }
    }

    /// Contact↔event links whose contact endpoint is an organization. Hidden
    /// when empty (unlike Linked Contacts, which keeps its placeholder row),
    /// matching the contact page's Linked Organizations section.
    @ViewBuilder
    private var linkedOrganizationsSection: some View {
        let organizationLinks = linkedConnections(where: .organization)
        if !organizationLinks.isEmpty {
            Section("Linked Organizations") {
                ForEach(organizationLinks, id: \.id) { link in
                    linkedContactRow(link)
                }
                .onDelete { offsets in
                    let ids = offsets.map { organizationLinks[$0].id }
                    for id in ids { remove(linkID: id) }
                }
            }
        }
    }

    @ViewBuilder
    private var linkedEventsSection: some View {
        if !linkedEventItems.isEmpty {
            Section("Linked Events") {
                ForEach(linkedEventItems, id: \.id) { link in
                    linkedEventRow(link)
                }
                .onDelete { offsets in
                    let ids = offsets.map { linkedEventItems[$0].id }
                    for id in ids { remove(linkID: id) }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedEventRow(_ link: ContactLink) -> some View {
        let other = SyncService.otherEndpoint(of: link, from: eventEndpoint)
        let linkedEvent = other.kind == .event ? service.event(uuid: other.id) : nil

        if let linkedEvent {
            Button {
                pushEventReference(
                    EventReference(
                        eventUUID: linkedEvent.id.uuidString,
                        eventKitID: linkedEvent.eventKitID
                    )
                )
            } label: {
                ActivityRowLayout(systemImage: "calendar") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(linkedEvent.title.isEmpty ? "(Untitled event)" : linkedEvent.title)
                        if !link.note.isEmpty {
                            Text(link.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        } else {
            ActivityRowLayout(systemImage: "calendar") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("(Unknown event)")
                        .foregroundStyle(.secondary)
                    if !link.note.isEmpty {
                        Text(link.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var linkActionsFooter: some View {
        DetailActivityFooter(actions: [
            DetailFooterAction(
                title: "Link Contact",
                systemImage: "person.line.dotted.person",
                isDisabled: event == nil,
                action: { showingPicker = true }
            ),
            DetailFooterAction(
                title: "Link Org",
                systemImage: "building.2",
                isDisabled: event == nil,
                action: { showingOrgPicker = true }
            ),
            DetailFooterAction(
                title: "Link Event",
                systemImage: "calendar.badge.plus",
                isDisabled: event == nil,
                action: { showingEventPicker = true }
            ),
        ])
    }

    @ViewBuilder
    private func linkedContactRow(_ link: ContactLink) -> some View {
        let contact = repository.linkedContact(of: link, forEventUUID: resolvedUUID)

        if let contact {
            Button {
                pushContactReference(ContactReference(id: contact.contactID))
            } label: {
                HStack(spacing: 12) {
                    ContactAvatar(contact: contact, diameter: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
                        if !link.note.isEmpty {
                            Text(link.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                UnknownContactAvatar(diameter: 28)
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
           let ekid = eventKitID
        {
            // Adoption spans awaits now. A reload arriving while another is
            // mid-adoption must BAIL, not fall through: reading against the
            // still-synthetic `resolvedUUID` below would render empty state.
            // The in-flight reload finishes and renders the adopted event.
            guard !adoptionInFlight else { return }
            adoptionInFlight = true
            defer { adoptionInFlight = false }
            if let existing = await service.eventUUID(forEventKitID: ekid) {
                resolvedUUID = existing.uuidString.lowercased()
            } else {
                do {
                    let minted = try await service.linkEvent(toEventKitID: ekid)
                    resolvedUUID = minted.uuidString.lowercased()
                } catch {
                    service.recordError("adopt event failed: \(error.localizedDescription)")
                }
            }
        }
        await service.refreshEvent(uuid: resolvedUUID)
        event = service.event(uuid: resolvedUUID)
        links = await service.links(at: eventEndpoint)
        notes = service.eventNotes(forEventUUID: resolvedUUID)
        tags = service.eventTags(forEventUUID: resolvedUUID)
        // Attendee→contact and linked-contact→contact resolution happen on
        // demand in the rows via the package repository's O(1) indexes, so
        // there's no app-side uuid/email→Contact map to build or hold here.
        hasLoadedOnce = true
    }

    /// Returns `true` when the link was created (or already existed) so the
    /// picker sheet knows it's safe to dismiss. A write failure returns `false`
    /// and surfaces via `service.recordError` so the user can pick a different
    /// contact or retry without losing the sheet.
    private func addLink(to contact: Contact, note: String) async -> Bool {
        do {
            // The link WRITE resolves-or-mints the CONTACT endpoint's GuessWho
            // UUID internally (linking a never-touched contact reconciles +
            // mints, transparent here), so there is no app-side reconcile. The
            // EVENT endpoint is the bare `resolvedUUID` until the deferred
            // event-identity migration.
            _ = try await repository.addEventLink(
                for: contact.contactID,
                eventUUID: resolvedUUID,
                note: note
            )
        } catch {
            service.recordError("add contact-event link failed: \(error.localizedDescription)")
            return false
        }
        await reload()
        return true
    }

    private func addEventLink(eventUUID: String, note: String) async {
        let other = SidecarKey(kind: .event, id: eventUUID)
        guard other != eventEndpoint else { return }
        do {
            _ = try service.addLink(from: eventEndpoint, to: other, note: note)
        } catch {
            service.recordError("add event-event link failed: \(error.localizedDescription)")
            return
        }
        await reload()
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
            // nil date = picker untouched — stamp "now" at save time.
            _ = try service.addEventNote(
                body: trimmed,
                createdAt: newNoteDate ?? Date(),
                forEventUUID: resolvedUUID
            )
            newNoteText = ""
            newNoteDate = nil
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
            // Re-stamp the date only when the user moved it, so an untouched
            // picker preserves the note's exact stored timestamp.
            let dateChanged = editingNoteDate != editingNoteDateSnapshot
            try service.editEventNote(
                id: id,
                newBody: trimmed,
                createdAt: dateChanged ? editingNoteDate : nil,
                forEventUUID: resolvedUUID
            )
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

struct ContactPickerSheet: View {
    @Environment(SyncService.self) private var service
    @Environment(ContactsRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    /// Which record type the picker offers: `.person` for "Add Contact",
    /// `.organization` for "Add Organization". The link write is identical —
    /// an organization is a `Contact` — so this only filters the list and
    /// swaps the copy.
    let kind: ContactType

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
                        Section(kind == .organization ? "Organization" : "Contact") {
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
                    List {
                        if filteredContacts.isEmpty {
                            Text(kind == .organization ? "No organizations." : "No contacts.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(filteredContacts, id: \.id) { entry in
                            Button {
                                selection = entry.contact
                            } label: {
                                Text(entry.contact.displayName)
                            }
                        }
                    }
                    .searchable(
                        text: $query,
                        prompt: kind == .organization ? "Search organizations" : "Search contacts"
                    )
                }
            }
            .navigationTitle(pickerTitle)
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
                                    errorMessage = kind == .organization
                                        ? "Couldn't add this organization. Try again or pick another."
                                        : "Couldn't add this contact. Try again or pick another."
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
            .task { contacts = repository.contacts.filter { $0.contactType == kind } }
        }
    }

    private var pickerTitle: String {
        if selection != nil { return "Add Link" }
        return kind == .organization ? "Pick Organization" : "Pick Contact"
    }

    /// Picker rows keyed by opaque `ContactID` (not raw `localID`) so the List's
    /// diffing identity is the app's stable GuessWho identity. `selection` stays
    /// a `Contact` because that's what `onPick` consumes.
    private var filteredContacts: [(id: ContactID, contact: Contact)] {
        let sorted = contacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [Contact]
        if trimmed.isEmpty {
            matched = sorted
        } else {
            let needle = trimmed.lowercased()
            matched = sorted.filter { $0.displayName.lowercased().contains(needle) }
        }
        return matched.map { (id: $0.contactID, contact: $0) }
    }
}
