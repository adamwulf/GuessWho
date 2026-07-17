import UIKit
import GuessWhoSync

/// Display state for a place row, driven by `GuidePlaceResolver`. Shared by
/// the per-guide places list and the unified Places tab so both render the
/// same plain-language resolution states.
enum PlaceRowStatus {
    /// Fully populated (an address entry, or a resolved place-ID entry).
    case resolved
    /// The resolver is looking this place up right now.
    case resolving
    /// Unresolved, and a pass is working through the queue toward it.
    case waiting
    /// Unresolved with no pass currently running.
    case idle
}

/// Place row: leading pin icon (or a spinner while this place is being looked
/// up), place name (with graceful fallbacks while details are still
/// resolving), an address caption, and — on the unified Places tab's flat
/// sorts — a guide-name caption so same-named places from different guides
/// stay distinguishable. Shared by `GuidePlacesListViewController` (which
/// never passes a guide name; the screen IS one guide) and
/// `PlacesListViewController`.
final class PlaceCell: UITableViewCell {
    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let nameLabel = UILabel()
    private let addressLabel = UILabel()
    private let guideLabel = UILabel()
    private let linkCountLabel = UILabel()
    // Spacing between the text stack and the link-count label; collapsed to 0
    // when the label is hidden so a linkless row reclaims the full width up to
    // the trailing margin (this cell has no star; see ContactCell rationale).
    private var textToLinkCountSpacing: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — PlaceCell is code-only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        addressLabel.text = nil
        addressLabel.isHidden = false
        guideLabel.text = nil
        guideLabel.isHidden = true
        linkCountLabel.text = nil
        linkCountLabel.isHidden = true
        textToLinkCountSpacing?.constant = 0
        showSpinner(false)
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listPlainCell().updated(for: state)
        if state.isSelected || state.isHighlighted {
            background.backgroundColor = .tintColor
            background.cornerRadius = 8
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
        }
        backgroundConfiguration = background
    }

    private func configureSubviews() {
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        iconView.image = UIImage(systemName: "mappin.and.ellipse")
        iconView.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1

        addressLabel.font = .preferredFont(forTextStyle: .caption1)
        addressLabel.textColor = .secondaryLabel
        addressLabel.adjustsFontForContentSizeCategory = true
        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        addressLabel.numberOfLines = 2

        // Guide-name caption, hidden unless the configure call supplies one
        // (only the unified Places tab does, and only in its flat sorts —
        // the By Guide sections already name the guide in their headers).
        guideLabel.font = .preferredFont(forTextStyle: .caption1)
        guideLabel.textColor = .tertiaryLabel
        guideLabel.adjustsFontForContentSizeCategory = true
        guideLabel.translatesAutoresizingMaskIntoConstraints = false
        guideLabel.numberOfLines = 1
        guideLabel.isHidden = true

        // Trailing "N links" caption, shown only when the place has at least one
        // link (hidden otherwise, so a linkless row looks unchanged).
        linkCountLabel.font = .preferredFont(forTextStyle: .caption1)
        linkCountLabel.textColor = .secondaryLabel
        linkCountLabel.adjustsFontForContentSizeCategory = true
        linkCountLabel.numberOfLines = 1
        linkCountLabel.isHidden = true
        linkCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        linkCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        linkCountLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [nameLabel, addressLabel, guideLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(spinner)
        contentView.addSubview(textStack)
        contentView.addSubview(linkCountLabel)

        let textToLinkCount = textStack.trailingAnchor.constraint(equalTo: linkCountLabel.leadingAnchor, constant: 0)
        textToLinkCountSpacing = textToLinkCount

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            // The spinner shares the icon's slot so text stays aligned whether a
            // row shows the pin or is being looked up.
            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            linkCountLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            linkCountLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textToLinkCount,
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func showSpinner(_ show: Bool) {
        iconView.isHidden = show
        if show {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    func configure(
        with place: MapsPlace,
        status: PlaceRowStatus,
        linkCount: Int,
        guideName: String? = nil
    ) {
        // Reset every configure so a recycled cell never shows a stale count.
        // The spacing constraint flips with visibility so a hidden label
        // collapses flush and the text reclaims the full width (see property).
        if linkCount > 0 {
            linkCountLabel.text = linkCount == 1 ? "1 link" : "\(linkCount) links"
            linkCountLabel.isHidden = false
            textToLinkCountSpacing?.constant = -8
        } else {
            linkCountLabel.text = nil
            linkCountLabel.isHidden = true
            textToLinkCountSpacing?.constant = 0
        }
        // The guide caption stays visible for unresolved rows too — on the
        // unified tab it is the only clue which guide a still-loading row
        // belongs to.
        let trimmedGuideName = guideName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guideLabel.text = trimmedGuideName.isEmpty ? nil : trimmedGuideName
        guideLabel.isHidden = trimmedGuideName.isEmpty
        switch status {
        case .resolved:
            showSpinner(false)
            nameLabel.textColor = .label
            let trimmedName = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                nameLabel.text = trimmedName
                addressLabel.text = place.address
                addressLabel.isHidden = (place.address?.isEmpty ?? true)
            } else if let address = place.address, !address.isEmpty {
                // Address entry (or a resolution that carried no name): the
                // address IS the title.
                nameLabel.text = address
                addressLabel.isHidden = true
            } else {
                // Resolved but empty — rare (MapKit returned no name/address).
                nameLabel.text = "(No details)"
                nameLabel.textColor = .secondaryLabel
                addressLabel.isHidden = true
            }
        case .resolving:
            showSpinner(true)
            placeholder("Looking up location…")
        case .waiting:
            showSpinner(false)
            placeholder("Waiting to load…")
        case .idle:
            showSpinner(false)
            placeholder("Loading place details…")
        }
    }

    /// Secondary-tinted single-line placeholder shown while a place-ID entry is
    /// still unresolved.
    private func placeholder(_ text: String) {
        nameLabel.text = text
        nameLabel.textColor = .secondaryLabel
        addressLabel.text = nil
        addressLabel.isHidden = true
    }
}
