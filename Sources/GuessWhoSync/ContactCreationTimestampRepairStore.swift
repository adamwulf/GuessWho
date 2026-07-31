import Foundation

/// A durable record of the creation instant captured after Contacts accepts a
/// new record but before the sidecar timestamps are known to be persisted.
/// `localID` is intentionally local-device repair state; the GuessWho UUID may
/// not exist yet when reconciliation is the part that failed.
struct ContactCreationTimestampRepair: Equatable, Sendable {
    let localID: String
    let createdAt: Date
}

/// Small persistence seam for creation timestamp repair. It is main-actor
/// confined with `ContactsRepository`; tests inject an isolated defaults suite
/// to prove a failed write survives repository reconstruction.
@MainActor
protocol ContactCreationTimestampRepairStoring: AnyObject {
    func pendingRepairs() -> [ContactCreationTimestampRepair]
    func record(localID: String, createdAt: Date)
    func remove(localID: String)
}

/// UserDefaults is used only as a retry journal, never as the timestamp source
/// of truth. Entries are removed immediately after the canonical sidecar write
/// succeeds (or after a successful Contacts reload proves the record vanished).
@MainActor
final class UserDefaultsContactCreationTimestampRepairStore:
    ContactCreationTimestampRepairStoring
{
    static let storageKey = "GuessWho.pendingContactCreationTimestamps.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func pendingRepairs() -> [ContactCreationTimestampRepair] {
        let stored = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        return stored.compactMap { localID, value in
            guard let interval = value as? TimeInterval else { return nil }
            return ContactCreationTimestampRepair(
                localID: localID,
                createdAt: Date(timeIntervalSinceReferenceDate: interval)
            )
        }
    }

    func record(localID: String, createdAt: Date) {
        var stored = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        stored[localID] = createdAt.timeIntervalSinceReferenceDate
        defaults.set(stored, forKey: Self.storageKey)
    }

    func remove(localID: String) {
        var stored = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        stored.removeValue(forKey: localID)
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(stored, forKey: Self.storageKey)
        }
    }
}
