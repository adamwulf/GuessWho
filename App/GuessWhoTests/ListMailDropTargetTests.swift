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
/// Serialized: each test shows its own window.
@MainActor
@Suite("List mail drop target", .serialized)
struct ListMailDropTargetTests {
    @Test
    func ourInteractionReplacesTheListsOwnWhileEnabledAndGivesThemBackWhileDisabled() async throws {
        let fixture = try DropTargetFixture()
        defer { fixture.tearDown() }

        let installer = try #require(await fixture.installer())
        let collectionView = try #require(installer.collectionView)
        let ours = installer.dropInteraction

        // The card's own list, not the other list next to it.
        #expect(collectionView.convert(collectionView.bounds, to: installer).intersects(installer.bounds))
        let otherList = try #require(fixture.collectionViews().first { $0 !== collectionView })
        #expect(!otherList.interactions.contains { $0 === ours })

        // Enabled: ours is the only drop interaction, and the list's own
        // ones are kept.
        #expect(Self.dropInteractions(of: collectionView).map(ObjectIdentifier.init) == [ObjectIdentifier(ours)])
        #expect(ours.delegate is MailDropInteractionDelegate)
        let originals = installer.keptInteractions
        #expect(!originals.isEmpty, "the List's collection view had no drop interaction of its own")

        // Disabled: ours is gone and the list's own are back.
        fixture.state.isEnabled = false
        #expect(try await fixture.waitUntil { ours.view == nil })
        #expect(Set(Self.dropInteractions(of: collectionView).map(ObjectIdentifier.init))
            == Set(originals.map(ObjectIdentifier.init)))
        #expect(installer.keptInteractions.isEmpty)

        // Enabled again: swapped back.
        fixture.state.isEnabled = true
        #expect(try await fixture.waitUntil { ours.view === collectionView })
        #expect(Self.dropInteractions(of: collectionView).map(ObjectIdentifier.init) == [ObjectIdentifier(ours)])
        #expect(Set(installer.keptInteractions.map(ObjectIdentifier.init)) == Set(originals.map(ObjectIdentifier.init)))
    }

    /// The card's monogram photo drop is a SwiftUI `.onDrop` inside a row,
    /// like this host's first row. SwiftUI keeps a drop interaction of its
    /// own on a view above the list (on macOS 27, the root hosting view), so
    /// a session this target refuses has another interaction above it. This
    /// checks only that the interaction is there and is not ours; whether a
    /// real image drag reaches it is a hand test.
    @Test
    func aViewAboveTheListKeepsADropInteractionThatIsNotOurs() async throws {
        let fixture = try DropTargetFixture()
        defer { fixture.tearDown() }
        let installer = try #require(await fixture.installer())
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
}

@MainActor
@Observable
private final class DropTargetState {
    var isEnabled = true
}

/// Two lists side by side, like the Catalyst window that also holds the
/// sidebar and the contact list. The target is on the second one, whose first
/// row has an image drop like the card's monogram.
private struct DropTargetHost: View {
    let state: DropTargetState

    var body: some View {
        HStack(spacing: 40) {
            List {
                Text("Other list")
            }
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
}

@MainActor
private struct DropTargetFixture {
    let state = DropTargetState()
    let window: UIWindow

    /// A window in the test host's scene.
    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.rootViewController = UIHostingController(rootView: DropTargetHost(state: state))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The installer, once it has found its collection view. The search runs
    /// on later main-actor turns, so this waits for it.
    func installer() async throws -> ListDropInstallerView? {
        var found: ListDropInstallerView?
        _ = try await waitUntil {
            found = descendants(of: window).lazy.compactMap { $0 as? ListDropInstallerView }.first
            return found?.collectionView != nil
        }
        return found
    }

    func collectionViews() -> [UICollectionView] {
        descendants(of: window).compactMap { $0 as? UICollectionView }
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
