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
    private let cache = NSCache<CacheKeyBox, UIImage>()
    private var inFlight: [CacheKey: Task<UIImage?, Never>] = [:]
    private var reloadObserver: NSObjectProtocol?

    init(repository: ContactsRepository, notificationCenter: NotificationCenter = .default) {
        self.repository = repository
        self.notificationCenter = notificationCenter
        reloadObserver = notificationCenter.addObserver(
            forName: .contactsRepositoryDidReload,
            object: repository,
            queue: .main
        ) { [weak self] _ in
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
        cache.object(forKey: CacheKeyBox(CacheKey(id: id, kind: kind)))
    }

    func image(for id: ContactID, kind: ContactPhotoKind) async -> UIImage? {
        let key = CacheKey(id: id, kind: kind)
        let boxed = CacheKeyBox(key)
        if let cached = cache.object(forKey: boxed) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let photo = try? await repository.contactPhotoData(for: id, kind: kind) else {
                return nil
            }
            return await Self.decodeImage(from: photo.data)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: boxed)
        }
        return image
    }

    func invalidate(_ id: ContactID?) {
        // v1 invalidation is coarse. The optional id keeps call sites future-proof
        // for package-vended per-contact invalidation without exposing localID.
        removeAll()
    }

    func removeAll() {
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
