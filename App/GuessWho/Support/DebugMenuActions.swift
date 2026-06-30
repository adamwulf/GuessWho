import UIKit
import GuessWhoLogging

/// Self-presenting actions for the two developer-facing **Help** menu items
/// ("Export Debug Logs" and "Open Container Folder"). These run from
/// `UICommand` actions installed by `GuessWhoAppDelegate.buildMenu(with:)`.
///
/// Why a self-presenting `@MainActor` enum rather than responder-chain
/// routing: a `UICommand`'s `action:` selector has to be implemented somewhere
/// live in the responder chain or the menu item greys out / silently does
/// nothing. By resolving the frontmost view controller ourselves (and
/// presenting from it) we don't depend on the chain for presentation at all,
/// which sidesteps that whole class of "menu item does nothing" bugs. The
/// `UICommand`s target the AppDelegate (always in the chain), and the
/// AppDelegate just forwards into these statics.
///
/// Both items are intentionally NOT gated behind debug mode: the whole point
/// is diagnosing a silent failure, so they must be reachable exactly when
/// something is broken. We guard the (nullable) App Group container URL and
/// surface a plain-copy alert rather than hide the item or no-op silently.
@MainActor
enum DebugMenuActions {

    // MARK: - Export Debug Logs

    /// Zip the shared `Logs/` directory off the main thread, then present a
    /// save panel (Catalyst) / share sheet (iOS) on the main thread. Failures
    /// surface in a plain-copy alert on the frontmost view controller.
    static func exportLogs() {
        let appGroupID = AppGroup.id
        // Zip creation touches the filesystem (coordination + copy) — keep it
        // off the main thread; present (and any failure alert) back on main.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = try LogExporter.exportLogs(appGroupID: appGroupID)
                Task { @MainActor in
                    presentExport(zipURL: zipURL)
                }
            } catch {
                Task { @MainActor in
                    presentFailure(
                        title: "Couldn't Export Logs",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private static func presentExport(zipURL: URL) {
        guard let presenter = topViewController() else { return }
        #if targetEnvironment(macCatalyst)
        // On Catalyst this surfaces the macOS save/export panel — the cleanest
        // cross-Catalyst path (no AppKit bridging). `.fullScreen` is REQUIRED
        // or Catalyst renders it as an in-window formSheet file browser instead
        // of bridging to the native NSSavePanel.
        let picker = UIDocumentPickerViewController(forExporting: [zipURL])
        picker.modalPresentationStyle = .fullScreen
        presenter.present(picker, animated: true)
        #else
        let activity = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
        // Anchor the popover to the presenter's view so it doesn't crash on iPad.
        activity.popoverPresentationController?.sourceView = presenter.view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY,
            width: 0,
            height: 0
        )
        activity.popoverPresentationController?.permittedArrowDirections = []
        presenter.present(activity, animated: true)
        #endif
    }

    // MARK: - Open Container Folder

    /// Reveal the App Group container directory. On Mac Catalyst,
    /// `UIApplication.shared.open` on a `file://` directory URL is routed by
    /// LaunchServices to Finder; on iOS the system handles it. No AppKit
    /// bridge / `NSWorkspace` needed.
    ///
    /// The container URL is nullable (entitlement / provisioning-profile
    /// mismatch can leave the App Group unresolved) — guard it and alert rather
    /// than force-unwrap. A not-yet-materialized dir or a sandbox refusal comes
    /// back as `success == false` in the completion handler instead of
    /// throwing, so we surface that too.
    static func openContainerFolder() {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) else {
            presentFailure(
                title: "Couldn't Open Folder",
                message: "The app's storage folder isn't available on this device yet."
            )
            return
        }

        UIApplication.shared.open(containerURL, options: [:]) { success in
            if !success {
                // The completion handler is not guaranteed to run on the main
                // thread — hop back to the main actor before resolving the top
                // VC and presenting.
                Task { @MainActor in
                    presentFailure(
                        title: "Couldn't Open Folder",
                        message: "Couldn't open the folder. It may not exist on this device yet."
                    )
                }
            }
        }
    }

    // MARK: - Shared presentation helpers

    /// The frontmost view controller to present from, walking past any
    /// already-presented controller. Prefers the `.foregroundActive` window
    /// scene and its key window (with fallbacks for Catalyst / multi-window and
    /// for the moment before a window becomes key), then walks past any sheet /
    /// alert / picker that's already up so we never present on a busy VC.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    /// Plain-copy failure alert on the frontmost VC (developer-facing surface).
    private static func presentFailure(title: String, message: String) {
        guard let presenter = topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}
