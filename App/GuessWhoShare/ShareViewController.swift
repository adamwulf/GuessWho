import UIKit
import UniformTypeIdentifiers
import os

/// Principal view controller for the GuessWho share extension (iOS only).
///
/// Its single job is the LinkedIn-app → Safari bounce: the user shares a
/// profile URL from the LinkedIn app (or anywhere else), and this extension
/// re-opens that URL in Safari, where the GuessWho LinkedIn Safari Web
/// Extension captures the profile through the normal handoff pipeline
/// (see docs/linkedin-safari-extension.md). Nothing is parsed or stored here —
/// no App Group, no Contacts, no iCloud. If the shared link isn't a LinkedIn
/// profile, we say so and bow out.
final class ShareViewController: UIViewController {

    private static let log = Logger(
        subsystem: "com.milestonemade.guesswho.share", category: "share")

    private var didStart = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let label = UILabel()
        label.text = "Opening in Safari…"
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The responder-chain walk in openViaResponderChain only reaches the
        // hosting UIApplication once the view is installed in a window, so the
        // work starts here rather than in viewDidLoad.
        guard !didStart else { return }
        didStart = true
        loadSharedProfileURL()
    }

    // MARK: - Attachment loading

    private func loadSharedProfileURL() {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { ($0 as? NSExtensionItem)?.attachments }
            .flatMap { $0 }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = Self.url(fromItem: item).flatMap(Self.linkedInProfileURL(from:))
                Task { @MainActor in self.finishLoading(url) }
            }
        } else if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            // Some apps share "Check out this profile: <url>" as plain text.
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let url = (item as? String).flatMap(Self.firstLinkedInProfileURL(inText:))
                Task { @MainActor in self.finishLoading(url) }
            }
        } else {
            finishLoading(nil)
        }
    }

    private func finishLoading(_ url: URL?) {
        guard let url else {
            Self.log.info("share item is not a LinkedIn profile URL")
            presentAlert(
                title: "Can’t Open This Link",
                message: "Share a LinkedIn profile link (linkedin.com/in/…) and it will open in Safari.")
            return
        }
        openInBrowser(url)
    }

    // MARK: - URL validation

    nonisolated private static func url(fromItem item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    /// Mirrors `LinkedInURL.isLinkedIn` in GuessWhoSync (the appex doesn't
    /// link the package): a profile URL has a linkedin.com host and an
    /// `/in/<slug>` path. Returns the URL upgraded to https, or nil if it
    /// isn't recognizably a LinkedIn profile. `lnkd.in` short links pass
    /// through untouched — Safari resolves the redirect.
    nonisolated private static func linkedInProfileURL(from raw: URL) -> URL? {
        guard var components = URLComponents(url: raw, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return nil }
        if host == "lnkd.in" { return raw }
        guard host == "linkedin.com" || host.hasSuffix(".linkedin.com") else { return nil }
        guard slug(fromPath: components.path) != nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The `<slug>` in an `/in/<slug>` path, or nil.
    nonisolated private static func slug(fromPath path: String) -> String? {
        guard let range = path.range(of: "/in/", options: .caseInsensitive) else { return nil }
        let slug = path[range.upperBound...].prefix { $0 != "/" }
        return slug.isEmpty ? nil : String(slug)
    }

    nonisolated private static func firstLinkedInProfileURL(inText text: String) -> URL? {
        let types: NSTextCheckingResult.CheckingType = .link
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, let profile = linkedInProfileURL(from: url) {
                return profile
            }
        }
        return nil
    }

    // MARK: - Opening Safari

    private func openInBrowser(_ url: URL) {
        // NSExtensionContext.open is only documented to work from Today
        // widgets and returns false from share extensions on current iOS,
        // but it is the sanctioned API — try it first, then fall back to
        // asking the hosting UIApplication up the responder chain.
        guard let context = extensionContext else { return }
        context.open(url) { opened in
            Task { @MainActor in
                if opened || self.openViaResponderChain(url) {
                    Self.log.info("opened profile in browser")
                    // Give the openURL: dispatch a beat before this process
                    // winds down; completing immediately can cancel the open.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                } else {
                    Self.log.error("no responder accepted openURL:")
                    self.presentAlert(
                        title: "Couldn’t Open Safari",
                        message: "Copy the profile link and open it in Safari instead.")
                }
            }
        }
    }

    /// `UIApplication.open` is unavailable in extension processes, but the
    /// hosting application at the top of the responder chain still answers
    /// `openURL:` — the long-standing share-extension escape hatch.
    private func openViaResponderChain(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return application.perform(NSSelectorFromString("openURL:"), with: url) != nil
            }
            responder = current.next
        }
        return false
    }

    // MARK: - Failure UI

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            Task { @MainActor in
                self.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        })
        present(alert, animated: true)
    }
}
