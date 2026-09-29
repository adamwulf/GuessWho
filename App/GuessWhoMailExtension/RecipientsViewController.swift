import AppKit
import MailKit
import SwiftUI

/// The view controller Mail shows in the compose-window popover. MailKit
/// requires an `MEExtensionViewController` subclass, so the SwiftUI list is
/// hosted in a child `NSHostingController`, and Mail sizes the popover from
/// this controller's `preferredContentSize`. The first size is measured in
/// `loadView()`, so the model already holds its rows by then (see
/// `RecipientsModel.showNow(_:)`). Later sizes (opening or leaving a detail
/// page, recipients changing) come from the view's `onSizeChange`: AppKit
/// never calls `preferredContentSizeDidChange(for:)` for a child's size
/// change, so forwarding the child's own preferred size would keep the
/// popover at its first size.
final class RecipientsViewController: MEExtensionViewController {

    private let model: RecipientsModel

    init(model: RecipientsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecipientsViewController is created in code only")
    }

    override func loadView() {
        let hostingController = NSHostingController(rootView: RecipientsView(model: model) { [weak self] size in
            self?.preferredContentSize = size
        })
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
        preferredContentSize = hostedView.fittingSize
    }
}
