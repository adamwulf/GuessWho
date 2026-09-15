#if DEBUG
import Foundation
import UIKit
import GuessWhoSync

/// Debug-only sample-data mode for screenshots.
///
/// When the process launches with the environment variable `GUESSWHO_SAMPLE=1`
/// (set by the "GuessWho (Sample)" scheme), the app runs against in-memory
/// Contacts / Calendar stores plus a throwaway sidecar root instead of the
/// user's real data. This lets us capture the marketing screenshots (see
/// `website/static/images/`) on Mac Catalyst — where the app otherwise reads
/// the Mac's real Contacts.app / Calendar.app — with a known, repeatable set of
/// people, an event, notes, tags, links, and favorites.
///
/// The sample stores live in the APP target (not `GuessWhoSyncTesting`): the app
/// must not link that product, because its intra-package dependency on the
/// `GuessWhoSync` target would statically fold a SECOND copy of `GuessWhoSync`
/// into the app and break the build (see `Package.swift` for the full note). The
/// app-hosted tests carry their own protocol stubs for the same reason; these
/// stores follow that sanctioned pattern.
///
/// Everything here is `#if DEBUG`, so a Release build neither compiles nor links
/// any of it and the sample flag has no effect.
enum SampleData {
    /// The launch environment variable the sample scheme sets.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GUESSWHO_SAMPLE"] == "1"
    }

    /// A `SyncService` wired to the in-memory sample stores and a fresh
    /// throwaway sidecar root. Nothing here touches the real Contacts, Calendar,
    /// iCloud container, or the device-local sync directory.
    @MainActor
    static func makeService() -> SyncService {
        // A fresh temp directory every launch: a clean slate so `seed` never
        // stacks duplicate notes/links/favorites on top of a previous run. The
        // OS purges the temporary directory, so nothing accumulates.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuessWhoSampleData-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cursorURL = root.appendingPathComponent("contact-sync-cursor.json")

        return SyncService(
            contactsAdapter: SampleContactStore(),
            eventsAdapter: SampleEventStore(),
            // `.localFallback` skips ubiquitous file coordination (there is no
            // second writer), which is exactly right for a private temp root.
            sidecarLocation: .localFallback(root, reason: "sample data mode"),
            deviceID: "sample-device",
            contactCursorURL: cursorURL
        )
    }

    /// Populate the sample stores. Idempotent per fresh service (each launch gets
    /// a clean temp sidecar), so calling once at launch is enough. Runs on the
    /// main actor; every write goes through the same production repository /
    /// service methods the UI uses, so the seeded data is indistinguishable from
    /// user-created data.
    @MainActor
    static func seed(service: SyncService, contacts: ContactsRepository) async {
        do {
            let now = Date()
            func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

            // MARK: Organizations
            //
            // Seed real organization contacts, not just company-name strings on
            // people. Without these records the Organizations list projects the
            // names as read-only phantoms, so their cards have no Edit button and
            // their department rows cannot navigate to department membership.
            for name in [
                "Apex Dynamics",
                "Horizon Ventures",
                "Northwind Labs",
                "Studio Mosaic",
                "Test Org",
            ] {
                _ = try await contacts.createContact(Contact(
                    contactType: .organization,
                    organizationName: name
                ))
            }

            // MARK: People
            //
            // The focused records match the website screenshots; the rest round
            // out the alphabetical index (A, B, H, L, P, R, T, V, Z) and the
            // Organizations tab.
            let elena = try await contacts.createContact(person(
                given: "Elena", family: "Rostova",
                title: "VP of Product", department: "Product Strategy",
                organization: "Apex Dynamics",
                phone: "+1 415-555-0142",
                email: "elena.rostova@apexdynamics.ai"
            )).contactID

            let marcus = try await contacts.createContact(person(
                given: "Marcus", family: "Vance",
                title: "Principal Engineer", organization: "Apex Dynamics",
                phone: "+1 415-555-0188",
                email: "marcus.vance@apexdynamics.ai"
            )).contactID

            let sarah = try await contacts.createContact(person(
                given: "Sarah", family: "Lin",
                title: "Partner", organization: "Horizon Ventures",
                email: "sarah@horizonvc.com"
            )).contactID

            _ = try await contacts.createContact(person(
                given: "Julian", family: "Thorne",
                title: "Design Director", organization: "Studio Mosaic"
            ))

            // David has no organization — mirrors the plain, subtitle-less row in
            // the people-list screenshot.
            _ = try await contacts.createContact(person(given: "David", family: "Taylor"))

            // A test contact that carries a photo (the checkerboard avatar).
            let zelda = try await contacts.createContact(person(
                given: "Zelda", family: "Photo", organization: "Test Org"
            )).contactID
            try await contacts.setContactPhoto(for: zelda, imageData: checkerboardPNG())

            // Index/Organizations filler.
            _ = try await contacts.createContact(person(
                given: "Priya", family: "Anand",
                title: "Founder", organization: "Northwind Labs"
            ))
            _ = try await contacts.createContact(person(
                given: "Daniel", family: "Brooks",
                title: "iOS Engineer", organization: "Apex Dynamics"
            ))
            _ = try await contacts.createContact(person(
                given: "Nina", family: "Hart",
                title: "Recruiter", organization: "Horizon Ventures"
            ))
            _ = try await contacts.createContact(person(
                given: "Wei", family: "Zhang",
                title: "Data Scientist", organization: "Apex Dynamics"
            ))

            // MARK: Elena's notes (dated) — the notes-view screenshot
            _ = try await contacts.addNote(
                for: elena,
                body: "met at swiftcraft 2026 in San Francisco. discussed ai agent "
                    + "orchestration architectures and offline-first mobile sync "
                    + "protocols. key partner for upcoming sdk rollout.",
                createdAt: minutesAgo(15)
            )
            _ = try await contacts.addNote(
                for: elena,
                body: "followed up on sdk design review. shared draft architecture "
                    + "diagrams and agreed on bi-weekly sync schedule.",
                createdAt: now
            )

            // MARK: Elena's linked contacts — the notes-view screenshot
            _ = try await contacts.addLink(from: elena, to: marcus, note: "")
            _ = try await contacts.addLink(from: elena, to: sarah, note: "")

            // MARK: The swiftcraft keynote event — the event-detail screenshot
            let start = Calendar.current.date(
                bySettingHour: 9, minute: 0, second: 0,
                of: Calendar.current.date(byAdding: .day, value: -2, to: now) ?? now
            ) ?? now
            let end = start.addingTimeInterval(60 * 60)
            let eventUUID = try service.createManualEvent(
                title: "swiftcraft 2026 keynote",
                startDate: start,
                endDate: end,
                isAllDay: false,
                location: "moscone west, San Francisco"
            ).uuidString

            _ = try service.addEventNote(
                body: "annual developer summit kickoff. met elena rostova and "
                    + "marcus vance after the opening keynote.",
                createdAt: minutesAgo(4),
                forEventUUID: eventUUID
            )
            _ = try service.addEventTag(text: "conference", forEventUUID: eventUUID)

            // Elena is linked to the event with an annotation.
            _ = try await contacts.addEventLink(
                for: elena,
                eventUUID: eventUUID,
                note: "keynote panelist on agentic ai workflows"
            )

            // MARK: Favorites — Elena and the keynote both carry a star.
            _ = try await contacts.toggleFavorite(elena)
            _ = try service.setFavorite(kind: .event, id: eventUUID, favorite: true)
        } catch {
            NSLog("[GuessWho] sample-data seeding failed: \(error)")
        }
    }

    // MARK: - Builders

    /// A person contact. `localID` stays empty here — the store mints one on
    /// `create`.
    private static func person(
        given: String,
        family: String,
        title: String = "",
        department: String = "",
        organization: String = "",
        phone: String? = nil,
        email: String? = nil
    ) -> Contact {
        Contact(
            givenName: given,
            familyName: family,
            jobTitle: title,
            departmentName: department,
            organizationName: organization,
            phoneNumbers: phone.map { [LabeledValue(label: "mobile", value: $0)] } ?? [],
            emailAddresses: email.map { [LabeledValue(label: "other", value: $0)] } ?? []
        )
    }

    /// A small checkerboard PNG for the sample "photo" contact.
    private static func checkerboardPNG() -> Data {
        let size = CGSize(width: 240, height: 240)
        let cells = 6
        let cell = size.width / CGFloat(cells)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let a = UIColor.systemIndigo
            let b = UIColor.systemPink
            for row in 0..<cells {
                for col in 0..<cells {
                    ((row + col) % 2 == 0 ? a : b).setFill()
                    context.fill(CGRect(
                        x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                        width: cell, height: cell
                    ))
                }
            }
        }
        return image.pngData() ?? Data()
    }
}

// MARK: - In-memory sample Contacts store

/// A minimal, functional `ContactStoreProtocol` for sample-data mode. Mints a
/// `localID` on `create` (via a JSON round-trip, since `Contact.localID` is
/// package-scoped and not settable from the app target) and keeps everything in
/// memory. Group support is present but inert — the sample never uses groups.
private actor SampleContactStore: ContactStoreProtocol {
    private var contactsByID: [String: Contact] = [:]
    private var photoByID: [String: Data] = [:]
    private var groupsByID: [String: ContactGroup] = [:]

    func fetchAll() async throws -> [Contact] { Array(contactsByID.values) }

    func fetch(localID: String) async throws -> Contact? { contactsByID[localID] }

    func save(_ contact: Contact) async throws {
        // The repository's mint path saves the URL-stamped contact back here;
        // key it by its (package-scoped) localID, read via the Codable form.
        contactsByID[Self.localID(of: contact)] = contact
    }

    func delete(localID: String) async throws {
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        contactsByID.removeValue(forKey: localID)
        photoByID.removeValue(forKey: localID)
    }

    func create(_ contact: Contact) async throws -> Contact {
        let localID = UUID().uuidString
        let created = Self.assigningLocalID(contact, localID)
        contactsByID[localID] = created
        return created
    }

    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .authorized }

    func requestContactsAccess() async -> StoreAccessResult {
        StoreAccessResult(status: .authorized)
    }

    func changes(since token: Data?) async throws -> ContactChangeSet {
        // Static store: the first (nil-token) read baselines with a full reload;
        // there are no external mutations after that.
        ContactChangeSet(changes: [], newToken: Data(count: 8), requiresFullReload: token == nil)
    }

    func loadImageData(localID: String) async throws -> Data? {
        guard contactsByID[localID] != nil else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        return photoByID[localID]
    }

    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await loadImageData(localID: localID)
    }

    func setImageData(localID: String, imageData: Data?) async throws {
        guard var contact = contactsByID[localID] else {
            throw ContactStoreError.contactNotFound(localID: localID)
        }
        if let imageData {
            photoByID[localID] = imageData
        } else {
            photoByID.removeValue(forKey: localID)
        }
        contact.imageDataAvailable = imageData != nil
        contactsByID[localID] = contact
    }

    // MARK: Groups (inert but valid)

    func fetchAllGroups() async throws -> [ContactGroup] { Array(groupsByID.values) }
    func fetchGroup(localID: String) async throws -> ContactGroup? { groupsByID[localID] }

    func createGroup(name: String) async throws -> ContactGroup {
        let group = ContactGroup(localID: UUID().uuidString, name: name)
        groupsByID[group.localID] = group
        return group
    }

    func renameGroup(localID: String, to name: String) async throws {
        guard var group = groupsByID[localID] else {
            throw ContactStoreError.groupNotFound(localID: localID)
        }
        group.name = name
        groupsByID[localID] = group
    }

    func deleteGroup(localID: String) async throws {
        groupsByID.removeValue(forKey: localID)
    }

    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { [] }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] { [] }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {}
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {}

    /// Reads a contact's package-scoped `localID` via its `Codable` form — the
    /// app target can't touch the property directly.
    private static func localID(of contact: Contact) -> String {
        guard
            let data = try? JSONEncoder().encode(contact),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let localID = object["localID"] as? String
        else {
            return ""
        }
        return localID
    }

    /// Returns a copy of `contact` with its (package-scoped) `localID` set. The
    /// app target can't assign `Contact.localID` directly, so we round-trip
    /// through the model's own `Codable` representation — the encode emits every
    /// stored key, so the decode never trips a missing-key error.
    private static func assigningLocalID(_ contact: Contact, _ localID: String) -> Contact {
        guard
            let data = try? JSONEncoder().encode(contact),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return contact
        }
        object["localID"] = localID
        guard
            let patched = try? JSONSerialization.data(withJSONObject: object),
            let decoded = try? JSONDecoder().decode(Contact.self, from: patched)
        else {
            return contact
        }
        return decoded
    }
}

// MARK: - In-memory sample Calendar store

/// An empty `EventStoreProtocol` for sample-data mode. Manual ("Add Other")
/// events are sidecar-only and never touch a calendar store, so every read
/// returns empty; authorization reports `.authorized` so no calendar-permission
/// banner appears.
private final class SampleEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .authorized }
    func requestEventsAccess() async -> StoreAccessResult { StoreAccessResult(status: .authorized) }
    func fetchEvents(in interval: DateInterval) throws -> [Event] { [] }
    func fetch(eventKitID: String) throws -> Event? { nil }
    func fetchEvents(on day: Date) throws -> [Event] { [] }
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] { [] }
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] { [] }
    func fetch(legacyEventIdentifier: String) throws -> Event? { nil }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event {
        throw EventStoreError.eventNotFound(eventKitID: "sample")
    }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws {}
}
#endif
