import Foundation
import UIKit
import GuessWhoSync

@MainActor
@Observable
final class ContactPhotoLoader {
    private struct CacheKey: Hashable {
        let id: ContactID
        let kind: ContactPhotoKind
    }

    private final class CacheKeyBox: NSObject {
        let key: CacheKey

        init(_ key: CacheKey) {
            self.key = key
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(key)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKeyBox else { return false }
            return key == other.key
        }
    }

    private let repository: ContactsRepository
    private let notificationCenter: NotificationCenter
    /// Holds `UIImage` for a loaded photo or `NSNull` for a confirmed
    /// no-photo result. Negative entries matter since the repository stopped
    /// pre-filtering on the unreliable `imageDataAvailable` flag: every
    /// nil now costs a store round-trip, so without caching it, each list
    /// scroll would re-query the store for every photo-less contact.
    private let cache = NSCache<CacheKeyBox, AnyObject>()
    private var inFlight: [CacheKey: Task<UIImage?, Never>] = [:]
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?
    private var cacheGeneration = 0

    init(repository: ContactsRepository, notificationCenter: NotificationCenter = .default) {
        self.repository = repository
        self.notificationCenter = notificationCenter
        reloadObserver = notificationCenter.addObserver(
            forName: .contactsRepositoryDidReload,
            object: repository,
            queue: .main
        ) { [weak self] note in
            // Presentation-only posts (sort flips, timestamp stamps) leave
            // every contact record — and therefore every decoded photo —
            // valid. Dropping the whole cache there forced every visible row
            // to refetch + re-decode its thumbnail on each contact open.
            // Absent key defaults to `true` (invalidate) for safety.
            let dataChanged = (note.userInfo?[
                ContactsRepositoryDidReloadKey.contactDataChanged
            ] as? Bool) ?? true
            guard dataChanged else { return }
            MainActor.assumeIsolated {
                self?.removeAll()
            }
        }
    }

    deinit {
        if let reloadObserver {
            notificationCenter.removeObserver(reloadObserver)
        }
    }

    func cachedImage(for id: ContactID, kind: ContactPhotoKind) -> UIImage? {
        cache.object(forKey: CacheKeyBox(CacheKey(id: id, kind: kind))) as? UIImage
    }

    func image(for id: ContactID, kind: ContactPhotoKind) async -> UIImage? {
        let key = CacheKey(id: id, kind: kind)
        let boxed = CacheKeyBox(key)
        if let cached = cache.object(forKey: boxed) {
            // NSNull is a cached "no photo" — don't hit the store again.
            return cached as? UIImage
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let generation = cacheGeneration
        let task = Task<UIImage?, Never> {
            guard let photo = try? await repository.contactPhotoData(for: id, kind: kind) else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let image = await Self.decodeImage(from: photo.data)
            guard !Task.isCancelled else { return nil }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        // A cancelled task also returns nil, but cancellation only happens via
        // removeAll(), which bumps the generation — so this guard keeps a
        // cancelled load from being cached as "no photo".
        guard cacheGeneration == generation else { return nil }
        cache.setObject(image ?? NSNull(), forKey: boxed)
        return image
    }

    func invalidate(_ id: ContactID?) {
        // v1 invalidation is coarse. The optional id keeps call sites future-proof
        // for package-vended per-contact invalidation without exposing localID.
        removeAll()
    }

    func removeAll() {
        cacheGeneration += 1
        cache.removeAllObjects()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    private static func decodeImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }
}
