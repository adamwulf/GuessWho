import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import GuessWho

/// The contact card's Mail drop target puts a UIKit drop interaction on the
/// `List`'s collection view in place of the collection view's own drop
/// interactions, and gives those back while it is disabled (FB24490454, see
/// `ListMailDropTarget`).
///
/// A `UIDropSession` cannot be built in a test, so the delegate's decisions
/// are covered by `MailDropReaderTests` (`MailDropReader.canAccept`).
///
/// Serialized: each test shows its own window. Each test is short: in an
/// unsigned build the test host can crash a few seconds after launch, for a
/// reason that has nothing to do with these tests.
@MainActor
@Suite("List mail drop target", .serialized)
struct ListMailDropTargetTests {
    @Test
    func ourInteractionReplacesTheListsOwnWhileEnabledAndGivesThemBackWhileDisabled() async throws {
        let state = DropTargetState()
        let card = UIHostingController(rootView: SideBySideHost(state: state))
        let window = try HostedWindow(root: card)
        defer { window.tearDown() }

        let installer = try #require(await window.installer(in: card.view))
        let collectionView = try #require(installer.collectionView)
        let ours = installer.dropInteraction

        // The card's own list, not the other list next to it.
        #expect(collectionView.convert(collectionView.bounds, to: installer).intersects(installer.bounds))
        let otherList = try #require(window.collectionViews(in: card.view).first { $0 !== collectionView })
        #expect(!otherList.interactions.contains { $0 === ours })

        // Enabled: ours is the only drop interaction, and the list's own
        // ones are kept.
        #expect(Self.ids(Self.dropInteractions(of: collectionView)) == [ObjectIdentifier(ours)])
        #expect(ours.delegate is MailDropInteractionDelegate)
        let originals = installer.keptInteractions
        #expect(!originals.isEmpty, "the List's collection view had no drop interaction of its own")

        // Disabled: ours is gone and the list's own are back.
        state.isEnabled = false
        #expect(try await window.waitUntil { ours.view == nil })
        #expect(Set(Self.ids(Self.dropInteractions(of: collectionView))) == Set(Self.ids(originals)))
        #expect(installer.keptInteractions.isEmpty)

        // Enabled again: swapped back.
        state.isEnabled = true
        #expect(try await window.waitUntil { ours.view === collectionView })
        #expect(Self.ids(Self.dropInteractions(of: collectionView)) == [ObjectIdentifier(ours)])
        #expect(Set(Self.ids(installer.keptInteractions)) == Set(Self.ids(originals)))
    }

    /// A collection view behind the card's hosting view overlaps the card.
    /// The search stays inside the card's own view controller, so it takes
    /// the card's list and leaves the one behind alone.
    @Test
    func aCollectionViewBehindTheCardIsNotTaken() async throws {
        let container = UIViewController()
        let behind = UICollectionView(frame: container.view.bounds, collectionViewLayout: UICollectionViewFlowLayout())
        behind.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(behind)
        let behindDrops = Self.ids(Self.dropInteractions(of: behind))

        let card = UIHostingController(rootView: TargetList(state: DropTargetState()))
        container.addChild(card)
        card.view.frame = container.view.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.view.addSubview(card.view)
        card.didMove(toParent: container)

        let window = try HostedWindow(root: container)
        defer { window.tearDown() }

        let installer = try #require(await window.installer(in: card.view))
        let collectionView = try #require(installer.collectionView)
        #expect(collectionView !== behind)
        #expect(collectionView.isDescendant(of: card.view))
        #expect(Self.ids(Self.dropInteractions(of: behind)) == behindDrops)
        #expect(Self.ids(Self.dropInteractions(of: collectionView)) == [ObjectIdentifier(installer.dropInteraction)])
    }

    /// A card pushed with animation over another card, as a contact
    /// reference pushes one: during the push both cards overlap in the same
    /// window. Each target must hold its own card's list.
    @Test
    func aCardPushedOverAnotherCardTakesItsOwnList() async throws {
        let first = UIHostingController(rootView: TargetList(state: DropTargetState()))
        let navigation = UINavigationController(rootViewController: first)
        let window = try HostedWindow(root: navigation)
        defer { window.tearDown() }
        let firstInstaller = try #require(await window.installer(in: first.view))

        let second = UIHostingController(rootView: TargetList(state: DropTargetState()))
        navigation.pushViewController(second, animated: true)
        let secondInstaller = try #require(await window.installer(in: second.view))
        #expect(try await window.waitUntil { navigation.transitionCoordinator == nil })

        let firstList = try #require(firstInstaller.collectionView)
        let secondList = try #require(secondInstaller.collectionView)
        #expect(firstList.isDescendant(of: first.view))
        #expect(secondList.isDescendant(of: second.view))
        #expect(Self.ids(Self.dropInteractions(of: firstList)) == [ObjectIdentifier(firstInstaller.dropInteraction)])
        #expect(Self.ids(Self.dropInteractions(of: secondList)) == [ObjectIdentifier(secondInstaller.dropInteraction)])
    }

    /// The card's monogram photo drop is a SwiftUI `.onDrop` inside a row,
    /// like this host's first row. SwiftUI keeps a drop interaction of its
    /// own on a view above the list (on macOS 27, the root hosting view), so
    /// a session this target refuses has another interaction above it. This
    /// checks only that the interaction is there and is not ours; whether a
    /// real image drag reaches it is a hand test.
    @Test
    func aViewAboveTheListKeepsADropInteractionThatIsNotOurs() async throws {
        let card = UIHostingController(rootView: SideBySideHost(state: DropTargetState()))
        let window = try HostedWindow(root: card)
        defer { window.tearDown() }
        let installer = try #require(await window.installer(in: card.view))
        let collectionView = try #require(installer.collectionView)

        var aboveTheList: [UIDropInteraction] = []
        var ancestor = collectionView.superview
        while let view = ancestor {
            aboveTheList += Self.dropInteractions(of: view)
            ancestor = view.superview
        }
        #expect(!aboveTheList.isEmpty)
        #expect(!aboveTheList.contains { $0 === installer.dropInteraction })
    }

    private static func dropInteractions(of view: UIView) -> [UIDropInteraction] {
        view.interactions.compactMap { $0 as? UIDropInteraction }
    }

    private static func ids(_ interactions: [UIDropInteraction]) -> [ObjectIdentifier] {
        interactions.map(ObjectIdentifier.init)
    }
}

@MainActor
@Observable
private final class DropTargetState {
    var isEnabled = true
}

/// A list with the drop target, whose first row has an image drop like the
/// card's monogram.
private struct TargetList: View {
    let state: DropTargetState

    var body: some View {
        List {
            Text("Header")
                .onDrop(of: [.image], isTargeted: nil) { _, _ in false }
            ForEach(0..<3, id: \.self) { Text("Row \($0)") }
        }
        .background {
            ListMailDropTarget(isEnabled: state.isEnabled, onDrop: { _ in })
        }
    }
}

/// Another list next to the target's, like the Catalyst sidebar next to the
/// card.
private struct SideBySideHost: View {
    let state: DropTargetState

    var body: some View {
        HStack(spacing: 40) {
            List {
                Text("Other list")
            }
            TargetList(state: state)
        }
    }
}

@MainActor
private struct HostedWindow {
    let window: UIWindow

    /// A window in the test host's scene, showing `root`.
    init(root: UIViewController) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The installer inside `root`, once it has found its collection view.
    /// The search runs on later main-actor turns, so this waits for it.
    func installer(in root: UIView) async throws -> ListDropInstallerView? {
        var found: ListDropInstallerView?
        _ = try await waitUntil {
            found = descendants(of: root).lazy.compactMap { $0 as? ListDropInstallerView }.first
            return found?.collectionView != nil
        }
        return found
    }

    func collectionViews(in root: UIView) -> [UICollectionView] {
        descendants(of: root).compactMap { $0 as? UICollectionView }
    }

    /// Runs the main run loop until `condition` holds, for at most 3 seconds.
    func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func descendants(of root: UIView) -> [UIView] {
        var result: [UIView] = []
        var queue = root.subviews[...]
        while let view = queue.popFirst() {
            result.append(view)
            queue.append(contentsOf: view.subviews)
        }
        return result
    }
}
