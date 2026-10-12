import SwiftUI
import UIKit
import GuessWhoLogging

/// The contact card's whole-profile drop target for Mail messages: a UIKit
/// `UIDropInteraction` on the backing `UICollectionView` of the `List` this
/// view is attached to, with `.background { ListMailDropTarget(...) }`.
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
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onDrop = onDrop
        installer.isEnabled = isEnabled
        // On every update: SwiftUI can add a new drop interaction of its own
        // to the collection view, for example when edit mode changes.
        installer.applyState()
    }

    static func dismantleUIView(_ installer: ListDropInstallerView, coordinator: MailDropInteractionDelegate) {
        installer.uninstall()
    }
}

/// Finds the `UICollectionView` of the `List` it is the background of, and
/// owns which drop interactions that collection view holds. Uses public UIKit
/// API only.
final class ListDropInstallerView: UIView {
    nonisolated private static let log = GuessWhoLog.logger("app.mail-drop")

    /// This target's interaction. UIKit holds an interaction's delegate weakly,
    /// so this view keeps the delegate too.
    let dropInteraction: UIDropInteraction
    private let delegate: any UIDropInteractionDelegate
    /// Set by `ListMailDropTarget`; `applyState()` acts on it.
    var isEnabled = true
    /// The list's collection view, once found.
    private(set) weak var collectionView: UICollectionView?
    /// The collection view's other drop interactions, removed while this
    /// target is enabled and added back when it is disabled.
    private(set) var keptInteractions: [UIDropInteraction] = []
    private var isSearching = false

    /// How often, and how far apart, the search runs before it gives up: the
    /// list's collection view can appear a moment after its background.
    private static let searchAttempts = 6
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
        guard window != nil, collectionView == nil, !isSearching else { return }
        isSearching = true
        search(attempt: 1)
    }

    private func search(attempt: Int) {
        guard window != nil else {
            isSearching = false
            return
        }
        if let found = nearestCollectionView() {
            isSearching = false
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

    /// The collection view that overlaps this view, searched from the nearest
    /// ancestor out. This view is a sibling of the list, not inside it, so
    /// each ancestor's descendants are searched, breadth first. On Catalyst
    /// the window also holds the sidebar and the contact list; nearest first
    /// and the overlap check keep their collection views out.
    private func nearestCollectionView() -> UICollectionView? {
        var ancestor = superview
        while let root = ancestor {
            var queue = root.subviews[...]
            while let view = queue.popFirst() {
                if let collectionView = view as? UICollectionView,
                   collectionView.convert(collectionView.bounds, to: self).intersects(bounds) {
                    return collectionView
                }
                queue.append(contentsOf: view.subviews)
            }
            ancestor = root.superview
        }
        return nil
    }

    /// Enabled: this target's interaction is the collection view's only drop
    /// interaction; any other one is removed and kept. Disabled: this
    /// target's interaction is removed and the kept ones are added back.
    func applyState() {
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
            if dropInteraction.view === collectionView {
                collectionView.removeInteraction(dropInteraction)
            }
            for kept in keptInteractions {
                collectionView.addInteraction(kept)
            }
            keptInteractions.removeAll()
        }
    }

    /// Leaves the collection view as it was before this target: SwiftUI is
    /// removing the list's background, and a `UIDropInteraction` whose
    /// delegate is gone must not stay on the list.
    func uninstall() {
        isEnabled = false
        applyState()
        collectionView = nil
    }
}

/// Decides and performs a Mail drop for `ListMailDropTarget`.
@MainActor
final class MailDropInteractionDelegate: NSObject, UIDropInteractionDelegate {
    nonisolated private static let log = GuessWhoLog.logger("app.mail-drop")

    var isEnabled = true
    var onDrop: @MainActor (MailDropReader.PendingDrop) -> Void = { _ in }
    /// The last session `canHandle` logged. UIKit can ask more than once per
    /// session; each session logs once.
    private weak var loggedSession: (any UIDropSession)?

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        let providers = session.items.map(\.itemProvider)
        let canHandle = isEnabled && MailDropReader.canAccept(providers)
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
                "enabled": isEnabled,
                "canHandle": canHandle,
            ])
        }
        return canHandle
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: isEnabled ? .copy : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        let providers = session.items.map(\.itemProvider)
        guard isEnabled, MailDropReader.canAccept(providers) else { return }
        // UIKit allows a drop's data to be requested only within
        // performDrop, so every load starts here, synchronously.
        onDrop(MailDropReader.startLoading(providers))
    }
}
