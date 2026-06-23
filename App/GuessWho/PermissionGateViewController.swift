import UIKit
import GuessWhoSync

/// Thin container that mirrors the SwiftUI `RootView` permission gate
/// in UIKit: while `SyncService.contactsAuthorization` is not
/// `.authorized` it presents a `UIContentUnavailableConfiguration`
/// describing the state (notRequested / denied / restricted); once
/// access flips to `.authorized` it swaps its child to the iPhone tab
/// bar VC handed in at init.
///
/// Used as the scene root on iPhone (and on iPad-compact / iPad-
/// regular until Phase 6 lifts iPad into the Catalyst-shaped
/// `UISplitViewController.tripleColumn` UIKit shell). The Catalyst
/// path constructs its split view directly and does not use this gate
/// — Mac users keep the same eager-load behaviour the AppDelegate
/// already drives there.
final class PermissionGateViewController: UIViewController {
    private let service: SyncService
    private let tabs: UIViewController
    private var currentChild: UIViewController?
    private var didKickAccessRequests = false

    init(service: SyncService, tabs: UIViewController) {
        self.service = service
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — PermissionGateViewController is code-only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        applyAuthorizationState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Kick the permission prompts on the first scene activation so
        // the system sheet appears once the user sees the gate's
        // "Requesting Contacts Access…" placeholder. Mirrors the
        // RootView.task ordering: contacts first, then events.
        guard !didKickAccessRequests else { return }
        didKickAccessRequests = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.service.requestContactsAccessIfNeeded()
            await self.service.requestEventsAccessIfNeeded()
        }
    }

    /// Re-render based on the current `contactsAuthorization`. We track
    /// the @Observable property via `withObservationTracking`, which
    /// re-invokes `onChange` exactly once on the next mutation — so the
    /// closure re-registers itself for the next round.
    private func applyAuthorizationState() {
        let auth = withObservationTracking {
            service.contactsAuthorization
        } onChange: { [weak self] in
            // onChange fires on the thread that performed the mutation;
            // SyncService is @MainActor so this is already main. Hop
            // explicitly so the snapshot replacement runs in main-actor
            // context regardless of how Observation evolves.
            Task { @MainActor [weak self] in
                self?.applyAuthorizationState()
            }
        }

        switch auth {
        case .authorized:
            installChild(tabs)
            contentUnavailableConfiguration = nil
        case .notRequested:
            installChild(nil)
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "person.2.fill")
            config.text = "Requesting Contacts Access…"
            config.secondaryText = "Approve the permission prompt to view your contacts."
            contentUnavailableConfiguration = config
        case .denied:
            installChild(nil)
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "person.crop.circle.badge.xmark")
            config.text = "Contacts Access Needed"
            config.secondaryText = "Open Settings and enable Contacts access for GuessWho."
            contentUnavailableConfiguration = config
        case .restricted:
            installChild(nil)
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "lock")
            config.text = "Contacts Restricted"
            config.secondaryText = "Contacts access is restricted on this device."
            contentUnavailableConfiguration = config
        }
    }

    /// Adopt `child` as the sole content child VC, removing whatever
    /// was previously installed. Passing nil clears the child so only
    /// `contentUnavailableConfiguration` shows.
    private func installChild(_ child: UIViewController?) {
        if currentChild === child { return }
        if let existing = currentChild {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
            currentChild = nil
        }
        guard let child else { return }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        child.didMove(toParent: self)
        currentChild = child
    }
}
