import Foundation
import CryptoKit

/// Two local hashes per contact, never photo bytes or a transient Contacts identifier.
/// The baseline survives relaunch and is not synced: another device may initially
/// observe a different system image while Contacts and file storage catch up.
struct ContactPhotoSourceTracker {
    let defaults: UserDefaults

    static func digest(_ data: Data?) -> String {
        guard let data else { return "none" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func systemPhotoChanged(key: SidecarKey, original: String, expected: String?, observed: String) -> Bool {
        let previous = defaults.stringArray(forKey: defaultsKey(key))
        // The expected system representation may arrive after its original/crop.
        // Recognizing it avoids mistaking normal Contacts sync for an external edit.
        if observed == expected { return false }
        guard let previous, previous.count == 2, previous[0] == original else { return false }
        return previous[1] != observed
    }

    func record(key: SidecarKey, original: String, observed: String) {
        defaults.set([original, observed], forKey: defaultsKey(key))
    }

    func remove(key: SidecarKey) { defaults.removeObject(forKey: defaultsKey(key)) }

    private func defaultsKey(_ key: SidecarKey) -> String { "contactPhotoSource.\(key.id)" }
}
