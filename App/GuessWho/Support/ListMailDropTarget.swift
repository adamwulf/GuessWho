import SwiftUI
import UIKit
import GuessWhoLogging

/// The contact card's whole-profile drop target for Mail messages and web
/// links: a UIKit `UIDropInteraction` on the backing `UICollectionView` of the
/// `List` this view is attached to, with `.background { ListMailDropTarget(...) }`.
/// Invisible, and it takes no touches.
///
/// Not SwiftUI's `.onDrop` on the `List`, because of FB24490454: a SwiftUI
/// `List` on iOS and Mac Catalyst is a `UICollectionView`, and the collection
/// view has a built-in `UIDropInteraction`. That interaction claims every drop
/// session from another app over the list and then refuses it, so SwiftUI's
/// drop handlers never see the session. The author of the workaround this
/// follows found that a second interaction next to it is not enough: the
/// built-in one still wins over the cells. So while the target is enabled,
/// the installer removes the collection view's other drop interactions and
/// keeps them; while it is disabled, it removes its own and puts the kept
/// ones back. Workaround source:
/// https://developer.apple.com/forums/content/attachment/75bcafd5-b927-465a-9648-b8fc856f556f
///
/// A session that `MailDropReader.canAccept(_:)` refuses (an image or a file
/// drag) is not claimed by this interaction, so UIKit can offer it to another
/// drop interaction.
struct ListMailDropTarget: UIViewRepresentable {
    /// False while the user edits the contact. The inline editor uses edit
    /// mode and `.onMove` reorder, so the collection view gets its own drop
    /// interactions back.
    let isEnabled: Bool
    /// Called inside `performDrop` with the loads already started.
    let onDrop: @MainActor (MailDropReader.PendingDrop) -> Void

    func makeCoordinator() -> MailDropInteractionDelegate {
        MailDropInteractionDelegate()
    }

    func makeUIView(context: Context) -> ListDropInstallerView {
        ListDropInstallerView(delegate: context.coordinator)
    }

    func updateUIView(_ installer: ListDropInstallerView, context: Context) {
        context.coordinator.onDrop = onDrop
        installer.update(isEnabled: isEnabled)
    }

    static func dismantleUIView(_ installer: ListDropInstallerView, coordinator: MailDropInteractionDelegate) {
        installer.uninstall()
    }
}

/// Finds the `UICollectionView` of the `List` it is the background of, and
/// owns which drop interactions that collection view holds: it is the one
/// owner of the enabled state. Uses public UIKit API only.
final class ListDropInstallerView: UIView {
    nonisolated private static let log = GuessWhoLog.logger("app.mail-drop")

    /// This target's interaction. UIKit holds an interaction's delegate weakly,
    /// so this view keeps the delegate too.
    let dropInteraction: UIDropInteraction
    private let delegate: any UIDropInteractionDelegate
    private var isEnabled = true
    /// The list's collection view, once found.
    private(set) weak var collectionView: UICollectionView?
    /// The collection view's other drop interactions, removed while this
    /// target is enabled and added back when it is disabled.
    private(set) var keptInteractions: [UIDropInteraction] = []
    private var isSearching = false

    /// How often, and how far apart, the search runs before it gives up: the
    /// list's collection view can join the view tree after this view joins
    /// the window.
    private static let searchAttempts = 20
    private static let searchInterval: Duration = .milliseconds(100)

    init(delegate: any UIDropInteractionDelegate) {
        self.delegate = delegate
        dropInteraction = UIDropInteraction(delegate: delegate)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — ListDropInstallerView is code-only")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if collectionView == nil {
            startSearch()
        }
    }

    /// Called on every SwiftUI update.
    func update(isEnabled: Bool) {
        self.isEnabled = isEnabled
        if let collectionView, window != nil, collectionView.window !== window {
            // The collection view this target holds is no longer in this
            // view's window: give it back its own interactions, then find
            // the list's collection view again.
            release()
            startSearch()
        }
        // Every update, in case UIKit or SwiftUI adds a drop interaction to
        // the collection view after this target's.
        applyState()
    }

    private func startSearch() {
        guard window != nil, !isSearching else { return }
        isSearching = true
        search(attempt: 1)
    }

    private func search(attempt: Int) {
        guard window != nil else {
            isSearching = false
            return
        }
        if let found = ownListCollectionView() {
            isSearching = false
            keptInteractions.removeAll()
            collectionView = found
            Self.log.info("list drop target installed", ["attempt": attempt])
            applyState()
            return
        }
        guard attempt < Self.searchAttempts else {
            isSearching = false
            Self.log.info("list drop target not found", ["attempts": attempt])
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.searchInterval)
            self?.search(attempt: attempt + 1)
        }
    }

    /// The first collection view, breadth first, in the view of the nearest
    /// view controller above this view (the card's own hosting controller)
    /// whose frame overlaps this view. This view is a sibling of the list,
    /// not inside it. The search never looks above that controller's view:
    /// a collection view behind the card, or the card below during a
    /// navigation push, can overlap this view too.
    private func ownListCollectionView() -> UICollectionView? {
        guard let root = owningControllerView() else { return nil }
        var queue = root.subviews[...]
        while let view = queue.popFirst() {
            if let collectionView = view as? UICollectionView,
               collectionView.convert(collectionView.bounds, to: self).intersects(bounds) {
                return collectionView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Walks the responder chain, not the superviews: a hosting view's next
    /// responder is not always its view controller, so the chain is followed
    /// until it reaches one.
    private func owningControllerView() -> UIView? {
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.viewIfLoaded
            }
            responder = current.next
        }
        return nil
    }

    /// Enabled: this target's interaction is the collection view's only drop
    /// interaction; any other one is removed and kept. Disabled: this
    /// target's interaction is removed and the kept ones are added back.
    private func applyState() {
        guard let collectionView else { return }
        if isEnabled {
            for case let other as UIDropInteraction in collectionView.interactions where other !== dropInteraction {
                collectionView.removeInteraction(other)
                keptInteractions.append(other)
            }
            if dropInteraction.view !== collectionView {
                collectionView.addInteraction(dropInteraction)
            }
        } else {
            restoreKeptInteractions(on: collectionView)
        }
    }

    private func restoreKeptInteractions(on collectionView: UICollectionView) {
        if dropInteraction.view === collectionView {
            collectionView.removeInteraction(dropInteraction)
        }
        for kept in keptInteractions {
            collectionView.addInteraction(kept)
        }
        keptInteractions.removeAll()
    }

    /// Leaves the collection view as it was before this target and forgets it.
    private func release() {
        if let collectionView {
            restoreKeptInteractions(on: collectionView)
        }
        keptInteractions.removeAll()
        collectionView = nil
    }

    /// SwiftUI is removing the list's background, and a `UIDropInteraction`
    /// whose delegate is gone must not stay on the list.
    func uninstall() {
        isEnabled = false
        release()
    }
}

/// Decides and performs a Mail drop for `ListMailDropTarget`. UIKit asks it
/// only while the installer has this target's interaction on the list, so it
/// has no enabled state of its own.
@MainActor
final class MailDropInteractionDelegate: NSObject, UIDropInteractionDelegate {
    nonisolated private static let log = GuessWhoLog.logger("app.mail-drop")

    var onDrop: @MainActor (MailDropReader.PendingDrop) -> Void = { _ in }
    /// The last session `canHandle` logged. UIKit can ask more than once per
    /// session; each session logs once.
    private weak var loggedSession: (any UIDropSession)?

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        let providers = session.items.map(\.itemProvider)
        let canHandle = MailDropReader.canAccept(providers)
        if loggedSession !== session {
            loggedSession = session
            // At info so the hand test shows what a Mail drag carries on
            // Catalyst, also when the answer is no. Type identifiers only:
            // never a subject, an address, or a file name.
            Self.log.info("mail drop session", [
                "items": providers.count,
                "types": providers.enumerated()
                    .map { "\($0.offset): \($0.element.registeredTypeIdentifiers.joined(separator: " "))" }
                    .joined(separator: " | "),
                "canHandle": canHandle,
            ])
        }
        return canHandle
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        let providers = session.items.map(\.itemProvider)
        guard MailDropReader.canAccept(providers) else { return }
        // UIKit allows a drop's data to be requested only within
        // performDrop, so every load starts here, synchronously.
        onDrop(MailDropReader.startLoading(providers))
    }
}
