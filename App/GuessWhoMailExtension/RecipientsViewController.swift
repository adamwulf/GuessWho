import AppKit
import MailKit
import SwiftUI

/// The view controller Mail shows in the compose-window popover. MailKit
/// requires an `MEExtensionViewController` subclass, so the SwiftUI list is
/// hosted in a child `NSHostingController` whose ideal size is forwarded as
/// this controller's `preferredContentSize` — the popover resizes as
/// recipients come and go.
final class RecipientsViewController: MEExtensionViewController {

    private let hostingController: NSHostingController<RecipientsView>

    init(model: RecipientsModel) {
        hostingController = NSHostingController(rootView: RecipientsView(model: model))
        hostingController.sizingOptions = [.preferredContentSize]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecipientsViewController is created in code only")
    }

    override func loadView() {
        view = NSView()
        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = hostingController.view.fittingSize
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === hostingController else { return }
        preferredContentSize = viewController.preferredContentSize
    }
}
