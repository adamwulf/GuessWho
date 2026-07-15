import UIKit
import UniformTypeIdentifiers
import os

/// Principal view controller for the GuessWho share extension (iOS only).
///
/// Bounce-only, two routes:
///
/// * a **LinkedIn profile URL** re-opens in Safari, where the GuessWho
///   LinkedIn Safari Web Extension captures the profile through the normal
///   handoff pipeline (see docs/linkedin-safari-extension.md);
/// * an **Apple Maps guide share link** (`maps.apple/ug/…`) bounces straight
///   into the GuessWho app via the app's wake scheme
///   (`…://import-guide?url=…`), where the guide is imported (see
///   docs/maps-guides.md).
///
/// Nothing is parsed or stored here — no App Group, no Contacts, no iCloud.
/// If the shared link is neither, we say so and bow out.
final class ShareViewController: UIViewController {

    private static let log = Logger(
        subsystem: "com.milestonemade.guesswho.share", category: "share")

    /// The app's wake scheme, mirrored from `LinkedInHandoffScheme` in the
    /// app target (the appex doesn't link the app's sources). Resolved from
    /// the `GuessWhoLinkedInURLScheme` Info.plist key (fed by
    /// `GUESSWHO_LINKEDIN_URL_SCHEME` in this target's xcconfig) so Debug and
    /// Release extensions wake the app built for the same configuration; an
    /// empty expansion falls back to the Release literal.
    /// `nonisolated`: read from the nonisolated URL-routing helpers below.
    nonisolated private static let appScheme: String =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoLinkedInURLScheme") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "guesswho-linkedin"

    private var didStart = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let label = UILabel()
        label.text = "Opening…"
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
        loadSharedURL()
    }

    // MARK: - Attachment loading

    private func loadSharedURL() {
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { ($0 as? NSExtensionItem)?.attachments }
            .flatMap { $0 }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = Self.url(fromItem: item).flatMap(Self.routedURL(from:))
                Task { @MainActor in self.finishLoading(url) }
            }
        } else if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            // Some apps share "Check out this profile: <url>" as plain text.
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let url = (item as? String).flatMap(Self.firstRoutedURL(inText:))
                Task { @MainActor in self.finishLoading(url) }
            }
        } else {
            finishLoading(nil)
        }
    }

    private func finishLoading(_ url: URL?) {
        guard let url else {
            Self.log.info("share item is not a LinkedIn profile or Apple Maps guide URL")
            presentAlert(
                title: "Can’t Open This Link",
                message: "Share a LinkedIn profile link (linkedin.com/in/…) or an Apple Maps guide link (maps.apple/ug/…).")
            return
        }
        openExternally(url)
    }

    // MARK: - Routing

    /// Map a shared URL to what this extension should open: a LinkedIn
    /// profile re-opens in Safari (the Safari Web Extension takes it from
    /// there); an Apple Maps guide link becomes the app's import wake URL.
    nonisolated private static func routedURL(from raw: URL) -> URL? {
        if let profile = linkedInProfileURL(from: raw) { return profile }
        if let wake = guideImportWakeURL(from: raw) { return wake }
        return nil
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

    /// Mirrors `MapsGuideURL.isGuideShareURL` in GuessWhoSync (the appex
    /// doesn't link the package): the short share form (`maps.apple/ug/…`)
    /// or the expanded web form (`maps.apple.com/guides…` / `…/ug…`).
    nonisolated private static func isMapsGuideURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return false }
        let path = components.path
        if host == "maps.apple" || host == "www.maps.apple" {
            return path.hasPrefix("/ug")
        }
        if host == "maps.apple.com" || host == "www.maps.apple.com" {
            return path.hasPrefix("/ug") || path.hasPrefix("/guides")
        }
        return false
    }

    /// The app wake URL for an Apple Maps guide share link:
    /// `<appScheme>://import-guide?url=<https share link>`. The app's scene
    /// delegate unwraps the `url` parameter and runs the import.
    ///
    /// The nested URL is percent-encoded by hand: `URLComponents.queryItems`
    /// legally leaves `&`/`=`/`?` bare inside a query VALUE, which would let
    /// an expanded guide link (`…guides?user=…`) split the wake URL's query
    /// and truncate the payload.
    nonisolated private static func guideImportWakeURL(from raw: URL) -> URL? {
        guard isMapsGuideURL(raw) else { return nil }
        guard var shareComponents = URLComponents(url: raw, resolvingAgainstBaseURL: false) else { return nil }
        if shareComponents.scheme?.lowercased() == "http" {
            shareComponents.scheme = "https"
        }
        guard let shareURL = shareComponents.url else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let encoded = shareURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(appScheme)://import-guide?url=\(encoded)")
    }

    nonisolated private static func firstRoutedURL(inText text: String) -> URL? {
        let types: NSTextCheckingResult.CheckingType = .link
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, let routed = routedURL(from: url) {
                return routed
            }
        }
        return nil
    }

    // MARK: - Opening Safari / the app

    private func openExternally(_ url: URL) {
        // NSExtensionContext.open is only documented to work from Today
        // widgets and returns false from share extensions on current iOS,
        // but it is the sanctioned API — try it first, then fall back to
        // asking the hosting UIApplication up the responder chain.
        guard let context = extensionContext else { return }
        context.open(url) { opened in
            Task { @MainActor in
                if opened || self.openViaResponderChain(url) {
                    Self.log.info("opened shared link (scheme=\(url.scheme ?? "-", privacy: .public))")
                    // Give the openURL: dispatch a beat before this process
                    // winds down; completing immediately can cancel the open.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                } else {
                    Self.log.error("no responder accepted openURL:")
                    self.presentAlert(
                        title: "Couldn’t Open This Link",
                        message: "Copy the link and open it in Safari or GuessWho instead.")
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
