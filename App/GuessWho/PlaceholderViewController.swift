import UIKit

/// Phase-2 column placeholder. Centers a single explanatory label so
/// the supplementary / secondary columns show *something* until the
/// real list views and detail view are ported over in Phase 3+.
final class PlaceholderViewController: UIViewController {
    private let label = UILabel()

    init(title: String, message: String) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
        label.text = message
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — PlaceholderViewController is code-only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    func update(title: String, message: String) {
        self.title = title
        label.text = message
    }
}
