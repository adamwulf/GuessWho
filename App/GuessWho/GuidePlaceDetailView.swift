import SwiftUI
import GuessWhoSync

/// Detail page for one place inside an imported guide. Pushed when a row in
/// `GuidePlacesListViewController` is tapped (previously the tap opened Apple
/// Maps directly — that action now lives here as a button).
///
/// Shows the place's name/address/coordinate with a link out to Apple Maps,
/// plus three best-effort "who/what is here" sections derived from the place's
/// address: recent calendar events at this location, and the contacts and
/// organizations whose address matches. Matching reuses the same street-line
/// token logic (`EventLocationMatcher`) the contact detail's "Recent Events"
/// section uses — a contact's structured street line must appear as a
/// contiguous run of words inside the place's address, so a shared city/state
/// alone never sweeps in unrelated records.
///
/// The place is read live from `GuidesRepository` (keyed by id) so its fields
/// repaint if the MapKit resolution pass lands while this page is open.
struct GuidePlaceDetailView: View {
    let placeID: UUID
    let guideID: UUID
    let repository: GuidesRepository

    @Environment(SyncService.self) private var service
    @Environment(ContactsRepository.self) private var contactsRepository
    @Environment(\.openURL) private var openURL

    // Bridge to the outer UIKit nav (both shells) so tapping an event, a
    // matched contact, or a guide pushes its detail. See `ReferenceNavigation.swift`.
    @Environment(\.pushEventReference) private var pushEventReference
    @Environment(\.pushContactReference) private var pushContactReference
    @Environment(\.pushGuideReference) private var pushGuideReference

    @State private var recentEvents: [Event] = []
    @State private var matchingPeople: [MatchedContact] = []
    @State private var matchingOrganizations: [MatchedContact] = []
    // The imported guides this place sits in — every guide whose places share
    // this place's street line (including this place's own guide). Populates the
    // "Guides" section; loaded alongside the other associations.
    @State private var containingGuides: [MapsGuide] = []
    @State private var links: [ContactLink] = []
    @State private var showingContactPicker = false
    @State private var showingOrganizationPicker = false
    @State private var showingEventPicker = false

    /// A contact matched to this place, paired with the street line that
    /// triggered the match (shown as the row caption). View-local — nothing
    /// here is persisted.
    private struct MatchedContact: Identifiable {
        let contact: Contact
        let street: String?
        var id: ContactID { contact.contactID }
    }

    /// The latest snapshot of this place. Reading `repository` (an `@Observable`)
    /// here makes the view repaint when a resolution pass or external change
    /// reloads the guides store.
    private var place: MapsPlace? {
        repository.places(inGuide: guideID).first { $0.id == placeID }
    }

    var body: some View {
        Form {
            if let place {
                locationSection(place)
                if !containingGuides.isEmpty {
                    guidesSection
                }
                if !recentEvents.isEmpty {
                    recentEventsSection
                }
                if !matchingPeople.isEmpty {
                    contactsSection(title: "Contacts", people: matchingPeople)
                }
                if !matchingOrganizations.isEmpty {
                    contactsSection(title: "Organizations", people: matchingOrganizations)
                }
                linkedContactsSection
                linkedOrganizationsSection
                linkedEventsSection
                Section { linkActionsFooter }
            } else {
                Text("This place is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(navigationTitle)
        #if !targetEnvironment(macCatalyst)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Recompute matches whenever the place's identity or resolved address
        // changes (the address arrives asynchronously for place-ID entries).
        .task(id: matchKey) {
            await reloadAssociations()
        }
        // Stamp lastViewed ONCE per open (not in the match task above, which
        // re-runs when the address resolves). Fire-and-forget: the package
        // no-ops when no sidecar exists, and the resulting sidecar change
        // drives the places list's debounced reload so a "Last Viewed" sort
        // re-orders. Mirrors the guide's on-open stamp.
        .task {
            service.stampPlaceViewed(uuid: placeID.uuidString)
            await reloadLinks()
        }
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerSheet(kind: .person) { contact, note in
                await addContactLink(to: contact, note: note)
            }
        }
        .sheet(isPresented: $showingOrganizationPicker) {
            ContactPickerSheet(kind: .organization) { contact, note in
                await addContactLink(to: contact, note: note)
            }
        }
        .sheet(isPresented: $showingEventPicker) {
            EventLinkSheet(mode: .link(onLinked: { eventUUID, note in
                Task { await addEventLink(eventUUID: eventUUID, note: note) }
            }))
        }
    }

    private var navigationTitle: String {
        guard let place else { return "Place" }
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if let address = place.address, !address.isEmpty { return address }
        return "Place"
    }

    /// Stable key for the association fetch: re-run when we point at a different
    /// place or when its address text changes (resolution landing).
    private var matchKey: String {
        guard let place else { return "" }
        return "\(place.id.uuidString)|\(place.address ?? "")"
    }

    // MARK: - Location

    @ViewBuilder
    private func locationSection(_ place: MapsPlace) -> some View {
        Section {
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if name.isEmpty && address.isEmpty {
                // Place-ID entry still waiting on its MapKit lookup — mirror the
                // list row's plain-language copy.
                Text("Loading place details…")
                    .foregroundStyle(.secondary)
            } else {
                if !name.isEmpty {
                    Text(name)
                        .font(.headline)
                }
                if !address.isEmpty {
                    Text(address)
                        .font(name.isEmpty ? .headline : .body)
                        .textSelection(.enabled)
                }
            }

            if let latitude = place.latitude, let longitude = place.longitude {
                LabeledContent("Coordinates") {
                    Text("\(latitude, specifier: "%.5f"), \(longitude, specifier: "%.5f")")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let url = mapsURL(for: place) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open in Maps", systemImage: "map")
                }
            }
        }
    }

    // MARK: - Guides

    /// The imported guides this place sits in. Reached here from the address
    /// summary row on a contact/event detail ("This place is in N guides");
    /// tapping a guide opens its places via `pushGuideReference`.
    @ViewBuilder
    private var guidesSection: some View {
        Section("Guides") {
            ForEach(containingGuides, id: \.id) { guide in
                Button {
                    pushGuideReference(GuideReference(guide: guide))
                } label: {
                    ActivityRowLayout(systemImage: "map") {
                        Text(guideName(guide))
                            .font(.body)
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The guide's name, falling back to the same "(Unnamed Guide)" placeholder
    /// the Guides list uses for a nameless import.
    private func guideName(_ guide: MapsGuide) -> String {
        let name = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "(Unnamed Guide)" : name
    }

    // MARK: - Recent events

    @ViewBuilder
    private var recentEventsSection: some View {
        Section("Recent Events") {
            ForEach(recentEvents, id: \.id) { event in
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
        }
    }

    // MARK: - Matched contacts / organizations

    @ViewBuilder
    private func contactsSection(title: LocalizedStringKey, people: [MatchedContact]) -> some View {
        Section(title) {
            ForEach(people) { matched in
                Button {
                    pushContactReference(ContactReference(id: matched.contact.contactID))
                } label: {
                    ActivityRowLayout(
                        systemImage: matched.contact.contactType == .organization ? "building.2" : "person.crop.circle"
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(matched.contact.displayName)
                                .font(.body)
                                .foregroundStyle(.tint)
                            if let street = matched.street, !street.isEmpty {
                                Text(street)
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
        }
    }

    // MARK: - Explicit links

    private var placeEndpoint: SidecarKey {
        SidecarKey(kind: .place, id: placeID.uuidString)
    }

    private func linkedContacts(where type: ContactType) -> [ContactLink] {
        links.filter { link in
            guard SyncService.otherEndpoint(of: link, from: placeEndpoint).kind == .contact else {
                return false
            }
            let contact = contactsRepository.linkedContact(of: link, at: placeEndpoint)
            return (contact?.contactType ?? .person) == type
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private var linkedEventItems: [ContactLink] {
        links.filter {
            SyncService.otherEndpoint(of: $0, from: placeEndpoint).kind == .event
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    private var linkedContactsSection: some View {
        linkedContactSection(title: "Linked Contacts", links: linkedContacts(where: .person))
    }

    @ViewBuilder
    private var linkedOrganizationsSection: some View {
        linkedContactSection(title: "Linked Organizations", links: linkedContacts(where: .organization))
    }

    @ViewBuilder
    private func linkedContactSection(title: String, links: [ContactLink]) -> some View {
        if !links.isEmpty {
            Section(title) {
                ForEach(links, id: \.id) { link in
                    linkedContactRow(link)
                }
                .onDelete { offsets in
                    for index in offsets {
                        removeLink(id: links[index].id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedContactRow(_ link: ContactLink) -> some View {
        let contact = contactsRepository.linkedContact(of: link, at: placeEndpoint)
        if let contact {
            Button {
                pushContactReference(ContactReference(id: contact.contactID))
            } label: {
                ActivityRowLayout {
                    ContactAvatar(contact: contact, diameter: 20)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.displayName)
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
            ActivityRowLayout {
                UnknownContactAvatar(diameter: 20)
            } content: {
                Text("(Unknown contact)")
                    .foregroundStyle(.secondary)
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
                    for index in offsets {
                        removeLink(id: linkedEventItems[index].id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedEventRow(_ link: ContactLink) -> some View {
        let other = SyncService.otherEndpoint(of: link, from: placeEndpoint)
        let event = other.kind == .event ? service.event(uuid: other.id) : nil
        if let event {
            Button {
                pushEventReference(
                    EventReference(eventUUID: event.id.uuidString, eventKitID: event.eventKitID)
                )
            } label: {
                ActivityRowLayout(systemImage: "calendar") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title.isEmpty ? "(Untitled event)" : event.title)
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
                Text("(Unknown event)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var linkActionsFooter: some View {
        DetailActivityFooter(actions: [
            DetailFooterAction(
                title: "Link Contact",
                systemImage: "person.line.dotted.person",
                action: { showingContactPicker = true }
            ),
            DetailFooterAction(
                title: "Link Org",
                systemImage: "building.2",
                action: { showingOrganizationPicker = true }
            ),
            DetailFooterAction(
                title: "Link Event",
                systemImage: "calendar.badge.plus",
                action: { showingEventPicker = true }
            ),
        ])
    }

    // MARK: - Data

    /// Fetch the events + contacts + organizations associated with this place's
    /// address. The event lookup hops to a background queue inside
    /// `SyncService.recentEvents`; the contact scan reads the already-loaded
    /// in-memory `contacts` array, so it stays on the main actor.
    private func reloadAssociations() async {
        guard let place, let needle = GuideAddressMatcher.streetNeedle(for: place) else {
            recentEvents = []
            matchingPeople = []
            matchingOrganizations = []
            containingGuides = []
            return
        }

        async let events = service.recentEvents(forEmails: [], addresses: [needle], limit: 10)
        async let guidesForPlace = service.guides(containingPlace: place)

        // Match contacts whose street line appears inside the place's address.
        let haystack = place.address
        let allContacts = contactsRepository.contacts
        let matched: [MatchedContact] = allContacts.compactMap { contact in
            let streets = contact.postalAddresses
                .map { $0.value.street.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let hit = streets.first(where: {
                EventLocationMatcher.matches(location: haystack, anyOf: [$0])
            }) else { return nil }
            return MatchedContact(contact: contact, street: hit)
        }

        recentEvents = await events
        containingGuides = await guidesForPlace
        matchingPeople = matched
            .filter { $0.contact.contactType == .person }
            .sorted { $0.contact.displayName.localizedCaseInsensitiveCompare($1.contact.displayName) == .orderedAscending }
        matchingOrganizations = matched
            .filter { $0.contact.contactType == .organization }
            .sorted { $0.contact.displayName.localizedCaseInsensitiveCompare($1.contact.displayName) == .orderedAscending }
    }

    private func reloadLinks() async {
        links = await service.links(at: placeEndpoint)
    }

    private func addContactLink(to contact: Contact, note: String) async -> Bool {
        do {
            _ = try await contactsRepository.addPlaceLink(
                for: contact.contactID,
                placeUUID: placeID.uuidString,
                note: note
            )
        } catch {
            service.recordError("add contact-place link failed: \(error.localizedDescription)")
            return false
        }
        await reloadLinks()
        return true
    }

    private func addEventLink(eventUUID: String, note: String) async {
        do {
            _ = try service.addLink(
                from: placeEndpoint,
                to: SidecarKey(kind: .event, id: eventUUID),
                note: note
            )
        } catch {
            service.recordError("add place-event link failed: \(error.localizedDescription)")
            return
        }
        await reloadLinks()
    }

    private func removeLink(id: UUID) {
        do {
            try service.removeLink(id: id)
        } catch {
            service.recordError("remove place link failed: \(error.localizedDescription)")
        }
        Task { await reloadLinks() }
    }

    // MARK: - Maps deep link

    /// Same deep-link shape the guide places list used: resolved (or place-ID)
    /// entries open via the durable place id; address entries fall back to
    /// coordinate + query.
    private func mapsURL(for place: MapsPlace) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/place")!
        if let placeID = place.mapsPlaceID {
            components.queryItems = [URLQueryItem(name: "place-id", value: placeID)]
        } else {
            components.path = "/"
            var items: [URLQueryItem] = []
            if let latitude = place.latitude, let longitude = place.longitude {
                items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
            }
            let query = place.name.isEmpty ? (place.address ?? "") : place.name
            if !query.isEmpty {
                items.append(URLQueryItem(name: "q", value: query))
            }
            guard !items.isEmpty else { return nil }
            components.queryItems = items
        }
        return components.url
    }
}
