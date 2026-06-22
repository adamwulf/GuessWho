import Foundation
import Contacts
import EventKit
import GuessWhoSync

@MainActor
@Observable
final class SyncService {
    enum SidecarLocation: Equatable {
        case iCloud(URL)
        case localFallback(URL, reason: String)
        // Fail-closed: no writable sidecar root could be resolved. Reads
        // return safe defaults, writes are refused with this reason.
        // Better than silently writing to a purgeable tmp dir.
        case unavailable(reason: String)
    }

    enum ContactsAuthorization: Equatable {
        case notRequested
        case denied
        case restricted
        case authorized
    }

    enum EventsAuthorization: Equatable {
        case notRequested
        case denied
        case restricted
        case authorized
    }

    private(set) var sidecarLocation: SidecarLocation
    private(set) var contactsAuthorization: ContactsAuthorization
    private(set) var eventsAuthorization: EventsAuthorization
    private(set) var lastError: String?

    // Exposed so view-models that mint records carrying a writer ID
    // (e.g. NotesStore stamping ContactNote.modifiedBy) stamp with the
    // same identifier the package's setField will stamp the outer cell
    // with. Same source, same value — avoids drifting writer-ID schemes.
    let deviceID: String

    private let contactStore: CNContactStore
    private let contactsAdapter: CNContactStoreAdapter
    private let eventStore: EKEventStore
    private let eventsAdapter: EKEventStoreAdapter
    private let sync: GuessWhoSync?

    // Known v1 limitation: sidecarLocation and sync are resolved once
    // in init() and never refreshed. If the app launches while iCloud
    // Drive is offline and the user signs in mid-session, the app
    // remains in .localFallback (or .unavailable) until relaunch.
    // A future refreshSidecarLocation() could rebuild `sync` on
    // ScenePhase.active transitions, but rebuilding the sidecar root
    // mid-session has implications (in-flight ops, cache state) that
    // are out of scope for the v1 sample.
    init() {
        // Single CNContactStore instance shared between this service and
        // the adapter, so contact-store state (auth prompt cache, etc.)
        // is consistent across the app.
        let store = CNContactStore()
        self.contactStore = store
        let adapter = CNContactStoreAdapter(store: store)
        self.contactsAdapter = adapter

        let ek = EKEventStore()
        self.eventStore = ek
        let ekAdapter = EKEventStoreAdapter(store: ek)
        self.eventsAdapter = ekAdapter

        let location = Self.resolveSidecarLocation()
        self.sidecarLocation = location

        let id = Self.stableDeviceID()
        self.deviceID = id

        switch location {
        case .iCloud(let url), .localFallback(let url, _):
            let sidecarStore = FileSystemSidecarStore(root: url)
            self.sync = GuessWhoSync(
                contacts: adapter,
                events: ekAdapter,
                sidecars: sidecarStore,
                deviceID: id
            )
        case .unavailable:
            self.sync = nil
        }

        self.contactsAuthorization = Self.readAuthorization()
        self.eventsAuthorization = Self.readEventsAuthorization()
    }

    func requestContactsAccessIfNeeded() async {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            contactsAuthorization = .authorized
        case .notDetermined:
            do {
                let granted = try await contactStore.requestAccess(for: .contacts)
                contactsAuthorization = granted ? .authorized : .denied
            } catch {
                contactsAuthorization = .denied
                lastError = "Contacts access request failed: \(error.localizedDescription)"
            }
        case .denied:
            contactsAuthorization = .denied
        case .restricted:
            contactsAuthorization = .restricted
        @unknown default:
            contactsAuthorization = .denied
        }
    }

    func requestEventsAccessIfNeeded() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            eventsAuthorization = .authorized
        case .authorized:
            // Pre-iOS-17 grant. Treat as authorized for read.
            eventsAuthorization = .authorized
        case .writeOnly:
            // Write-only access does not let us read events; surface as denied.
            eventsAuthorization = .denied
        case .notDetermined:
            do {
                if #available(iOS 17.0, macCatalyst 17.0, macOS 14.0, *) {
                    let granted = try await eventStore.requestFullAccessToEvents()
                    eventsAuthorization = granted ? .authorized : .denied
                } else {
                    let granted = try await eventStore.requestAccess(to: .event)
                    eventsAuthorization = granted ? .authorized : .denied
                }
            } catch {
                eventsAuthorization = .denied
                lastError = "Events access request failed: \(error.localizedDescription)"
            }
        case .denied:
            eventsAuthorization = .denied
        case .restricted:
            eventsAuthorization = .restricted
        @unknown default:
            eventsAuthorization = .denied
        }
    }

    func fetchEventsRange(from start: Date, to end: Date) -> [Event] {
        guard eventsAuthorization == .authorized else { return [] }
        do {
            return try eventsAdapter.fetchEvents(in: DateInterval(start: start, end: end))
        } catch {
            lastError = "fetchEvents failed: \(error.localizedDescription)"
            return []
        }
    }

    // TODO(phase 5): rework per EVENT_STRATEGY_PLAN.md E2.1 — switch to
    // `event(uuid:)` routed through the orchestrator's Option C projection.
    // Minimal phase 1 change: rename the adapter call from `fetch(externalID:)`
    // to `fetch(eventKitID:)` to satisfy the new EventStoreProtocol.
    func event(externalID: String) -> Event? {
        guard eventsAuthorization == .authorized else { return nil }
        do {
            return try eventsAdapter.fetch(eventKitID: externalID)
        } catch {
            lastError = "event fetch failed: \(error.localizedDescription)"
            return nil
        }
    }

    func fetchAll() -> [Contact] {
        guard contactsAuthorization == .authorized else { return [] }
        do {
            return try contactsAdapter.fetchAll()
        } catch {
            lastError = "fetchAll failed: \(error.localizedDescription)"
            return []
        }
    }

    func sidecar(for contact: Contact) -> SidecarEnvelope? {
        guard let uuid = guessWhoUUID(in: contact) else { return nil }
        guard let sync else { return nil }
        do {
            return try sync.sidecar(at: SidecarKey(kind: .contact, id: uuid))
        } catch {
            lastError = "sidecar read failed: \(error.localizedDescription)"
            return nil
        }
    }

    func guessWhoUUID(in contact: Contact) -> String? {
        for url in contact.urlAddresses {
            if let uuid = SidecarKey.parseGuessWhoContactURL(url.value) {
                return uuid
            }
        }
        return nil
    }

    func reconcile(localID: String) throws -> IdentityReconcileReport.ContactOutcome {
        guard let sync else {
            throw SidecarUnavailableError()
        }
        return try sync.reconcileContactIdentity(localID: localID)
    }

    // MARK: - Notes

    func notes(forContactUUID uuid: String) -> [ContactNote] {
        guard let sync else { return [] }
        do {
            return try sync.notes(at: SidecarKey(kind: .contact, id: uuid))
        } catch {
            lastError = "notes read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addNote(body: String, forContactUUID uuid: String) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addNote(at: SidecarKey(kind: .contact, id: uuid), body: body)
    }

    func editNote(id: UUID, newBody: String, forContactUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.editNote(at: SidecarKey(kind: .contact, id: uuid), id: id, newBody: newBody)
    }

    func deleteNote(id: UUID, forContactUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deleteNote(at: SidecarKey(kind: .contact, id: uuid), id: id)
    }

    // MARK: - Contact Links

    func contactLinks(forContactUUID uuid: String) -> [Link] {
        guard let sync else { return [] }
        do {
            let all = try sync.links(at: SidecarKey(kind: .contact, id: uuid))
            return all.filter { $0.deletedAt == nil }
        } catch {
            lastError = "links read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addContactLink(fromUUID: String, toUUID: String, note: String) throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addLink(
            from: SidecarKey(kind: .contact, id: fromUUID),
            to: SidecarKey(kind: .contact, id: toUUID),
            note: note
        )
    }

    func setContactLinkNote(id: UUID, note: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.setLinkNote(id: id, note: note)
    }

    func removeContactLink(id: UUID) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.removeLink(id: id)
    }

    /// Reverse of `guessWhoUUID(in:)`: finds the contact whose GuessWho URL
    /// carries `uuid`. Returns nil if no current contact owns that UUID
    /// (e.g. the contact was deleted from the address book).
    func contact(forGuessWhoUUID uuid: String) -> Contact? {
        let target = uuid.lowercased()
        for contact in fetchAll() {
            if let owned = guessWhoUUID(in: contact), owned == target {
                return contact
            }
        }
        return nil
    }

    // MARK: - Contact ↔ Event links

    func eventLinks(forContactUUID uuid: String) -> [Link] {
        guard let sync else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: uuid)
        do {
            let all = try sync.links(at: endpoint)
            return all.filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .event
            }
        } catch {
            lastError = "event links read failed: \(error.localizedDescription)"
            return []
        }
    }

    func contactLinks(forEventID externalID: String) -> [Link] {
        guard let sync else { return [] }
        let endpoint = SidecarKey(kind: .event, id: externalID)
        do {
            let all = try sync.links(at: endpoint)
            return all.filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .contact
            }
        } catch {
            lastError = "contact links read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addContactEventLink(contactUUID: String, eventID: String, note: String) throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addLink(
            from: SidecarKey(kind: .contact, id: contactUUID),
            to: SidecarKey(kind: .event, id: eventID),
            note: note
        )
    }

    func removeLink(id: UUID) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.removeLink(id: id)
    }

    static func otherEndpoint(of link: Link, from endpoint: SidecarKey) -> SidecarKey {
        link.endpointA == endpoint ? link.endpointB : link.endpointA
    }

    func recordError(_ message: String) {
        lastError = message
    }

    // MARK: - Private

    private static func resolveSidecarLocation() -> SidecarLocation {
        let fm = FileManager.default
        if let ubiquity = fm.url(forUbiquityContainerIdentifier: "iCloud.com.milestonemade.guesswho") {
            let documents = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            do {
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                return .iCloud(documents)
            } catch {
                // iCloud container exists but is unwritable — try local
                // fallback before giving up.
                if let local = try? localFallbackURL() {
                    return .localFallback(
                        local,
                        reason: "iCloud container found but its Documents folder is unwritable: \(error.localizedDescription)"
                    )
                }
                return .unavailable(
                    reason: "iCloud container is unwritable and no local fallback directory is available."
                )
            }
        }

        if let local = try? localFallbackURL() {
            return .localFallback(
                local,
                reason: "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive to sync across devices."
            )
        }
        return .unavailable(
            reason: "No writable storage location is available. Application Support is unavailable on this device."
        )
    }

    private static func localFallbackURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("GuessWhoSidecars", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stableDeviceID() -> String {
        let defaults = UserDefaults.standard
        let key = "com.milestonemade.guesswho.deviceID"
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: key)
        return fresh
    }

    private static func readAuthorization() -> ContactsAuthorization {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notRequested
        @unknown default: return .denied
        }
    }

    private static func readEventsAuthorization() -> EventsAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .authorized
        case .writeOnly: return .denied
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notRequested
        @unknown default: return .denied
        }
    }
}

struct SidecarUnavailableError: Error, LocalizedError {
    var errorDescription: String? {
        "Sidecar storage is unavailable. Cannot read or write GuessWho data."
    }
}
