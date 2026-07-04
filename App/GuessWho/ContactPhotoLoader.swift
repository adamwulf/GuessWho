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
    private var inFlight: [CacheKey: Task<LoadOutcome, Never>] = [:]
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

    /// The three ways a load can come back, kept distinct so only DEFINITIVE
    /// results are cached: a thrown store error must stay retryable — a
    /// transient Contacts hiccup negative-cached as "no photo" would blank the
    /// photo until the next data-changed reload, even after the store recovers.
    private enum LoadOutcome {
        case loaded(UIImage)
        /// The store answered and there are no displayable bytes (or the bytes
        /// don't decode, which is deterministic until the record changes).
        case noPhoto
        /// The load threw or was cancelled — report nil, cache nothing.
        case failed
    }

    func image(for id: ContactID, kind: ContactPhotoKind) async -> UIImage? {
        let key = CacheKey(id: id, kind: kind)
        let boxed = CacheKeyBox(key)
        if let cached = cache.object(forKey: boxed) {
            // NSNull is a cached "no photo" — don't hit the store again.
            return cached as? UIImage
        }
        if let task = inFlight[key] {
            if case .loaded(let image) = await task.value { return image }
            return nil
        }

        let generation = cacheGeneration
        let task = Task<LoadOutcome, Never> {
            let photo: ContactPhoto?
            do {
                photo = try await repository.contactPhotoData(for: id, kind: kind)
            } catch {
                return .failed
            }
            guard let photo else { return .noPhoto }
            guard !Task.isCancelled else { return .failed }
            guard let image = await Self.decodeImage(from: photo.data) else {
                return .noPhoto
            }
            guard !Task.isCancelled else { return .failed }
            return .loaded(image)
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        // A cancelled task reports .failed, and cancellation only happens via
        // removeAll(), which bumps the generation — so this guard is a second
        // line of defense against caching a torn-down load.
        guard cacheGeneration == generation else { return nil }
        switch outcome {
        case .loaded(let image):
            cache.setObject(image, forKey: boxed)
            return image
        case .noPhoto:
            cache.setObject(NSNull(), forKey: boxed)
            return nil
        case .failed:
            return nil
        }
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
