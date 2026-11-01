import Foundation
import CryptoKit

/// Two local hashes and an optional ignored pointer revision per contact, never photo
/// bytes or a transient Contacts identifier.
/// The baseline survives relaunch and is not synced: another device may initially
/// observe a different system image while Contacts and file storage catch up.
struct ContactPhotoSourceTracker {
    let defaults: UserDefaults

    static func digest(_ data: Data?) -> String {
        guard let data else { return "none" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `revision` changes with every explicit write to the pointer. Choosing a photo
    /// again reuses its blob ID, so a blob ID alone can't show a new choice was made.
    func usesSystemPhoto(key: SidecarKey, original: String, revision: String, expected: String?, observed: String) -> Bool {
        let previous = defaults.stringArray(forKey: defaultsKey(key))
        var ignoredRevision = ""
        if let previous, previous.count == 3, previous[0] == original {
            ignoredRevision = previous[2]
            if !ignoredRevision.isEmpty {
                // Only a new explicit crop/save can restore the same original's
                // framing. Keep the ignored marker until its system bytes arrive.
                if revision != ignoredRevision, observed == expected { ignoredRevision = "" }
            } else if previous[1] != observed, observed != expected {
                ignoredRevision = revision
            }
        }
        defaults.set([original, observed, ignoredRevision], forKey: defaultsKey(key))
        return !ignoredRevision.isEmpty
    }

    func record(key: SidecarKey, original: String, observed: String) {
        defaults.set([original, observed, ""], forKey: defaultsKey(key))
    }

    func remove(key: SidecarKey) { defaults.removeObject(forKey: defaultsKey(key)) }

    private func defaultsKey(_ key: SidecarKey) -> String { "contactPhotoSource.\(key.id)" }
}
