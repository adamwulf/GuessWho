import Foundation
import Contacts
import GuessWhoSync

// A no-op EventStoreProtocol so v0 of the app does not need EventKit
// permission or even a calendar at all.
final class NoopEventStore: EventStoreProtocol {
    func fetchEvents(in interval: DateInterval) throws -> [Event] { [] }
    func fetch(externalID: String) throws -> Event? { nil }
}

@MainActor
@Observable
final class SyncService {
    enum SidecarLocation: Equatable {
        case iCloud(URL)
        case localFallback(URL, reason: String)
    }

    enum ContactsAuthorization: Equatable {
        case notRequested
        case denied
        case restricted
        case authorized
    }

    private(set) var sidecarLocation: SidecarLocation
    private(set) var contactsAuthorization: ContactsAuthorization
    private(set) var lastError: String?

    private let contactStore = CNContactStore()
    private let contactsAdapter: CNContactStoreAdapter
    private let sidecarStore: FileSystemSidecarStore
    private let sync: GuessWhoSync

    init() {
        let location = Self.resolveSidecarLocation()
        self.sidecarLocation = location

        let rootURL: URL = {
            switch location {
            case .iCloud(let url): return url
            case .localFallback(let url, _): return url
            }
        }()

        let adapter = CNContactStoreAdapter()
        self.contactsAdapter = adapter

        let store = FileSystemSidecarStore(root: rootURL)
        self.sidecarStore = store

        self.sync = GuessWhoSync(
            contacts: adapter,
            events: NoopEventStore(),
            sidecars: store,
            deviceID: Self.stableDeviceID()
        )

        self.contactsAuthorization = Self.readAuthorization()
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
        try sync.reconcileContactIdentity(localID: localID)
    }

    func setField(_ name: String, value: JSONValue, forContactUUID uuid: String) throws {
        try sync.setField(name, value: value, at: SidecarKey(kind: .contact, id: uuid))
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
                let fallback = localFallbackURL()
                return .localFallback(
                    fallback,
                    reason: "iCloud container found but its Documents folder is unwritable: \(error.localizedDescription)"
                )
            }
        }

        let fallback = localFallbackURL()
        return .localFallback(
            fallback,
            reason: "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive to sync across devices."
        )
    }

    private static func localFallbackURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("GuessWhoSidecars", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
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
}
