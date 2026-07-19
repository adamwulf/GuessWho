// AppKitPlugin.swift
// The @objc contract between the Catalyst app and the native-macOS
// AppKitBridge bundle. Mac Catalyst can't link AppKit, so anything that
// touches `NSOpenPanel` lives in a separate loadable macOS `.bundle`
// (SDKROOT=macosx) that the app loads at runtime and calls across this
// protocol, resolved through the Obj-C runtime.
//
// IMPORTANT: this ONE file is compiled into BOTH targets — the GuessWho app
// (so call sites can name `AppKitPlugin`) and the GuessWhoAppKitBridge bundle
// (so the impl conforms to the identical @objc protocol). Both sides must see
// a byte-identical @objc protocol because the call crosses a
// dynamically-loaded module boundary. Everything that crosses the boundary
// must be Obj-C-representable (String, Bool, URL, an @escaping closure with
// Obj-C-compatible params) — no Swift enums/structs/UTType across the line.

import Foundation

@objc(AppKitPlugin)
public protocol AppKitPlugin: NSObjectProtocol {
    /// The loader instantiates the principal class via `pluginClass.init()`.
    init()

    /// Presents a native macOS file Open panel (in-process, so its selection
    /// is blessed against the host app's sandbox) and hands the chosen file
    /// URLs back on the main thread.
    ///
    /// - Parameters:
    ///   - allowedExtensions: lowercase file extensions to allow, e.g.
    ///     `["png", "jpg", "jpeg", "heic"]`. Empty means "any file."
    ///   - allowsMultiple: whether the user may select more than one file.
    ///   - completion: called on the MAIN thread with the picked URLs.
    ///     An empty array means the user cancelled.
    func presentOpenPanel(
        allowedExtensions: [String],
        allowsMultiple: Bool,
        completion: @escaping ([URL]) -> Void
    )

    /// Creates the `/usr/local/bin` symlink for the embedded command-line
    /// helper behind the system admin-authorization panel (the Muse-proven
    /// mechanism: `NSWorkspace.requestAuthorization(to: .createSymbolicLink)`
    /// + `FileManager(authorization:)` — a runtime auth API, no bespoke
    /// entitlement). AppKit-side because both APIs are AppKit/macOS-only.
    ///
    /// - Parameters:
    ///   - targetPath: the bundle's helper binary (the symlink destination).
    ///   - symlinkPath: where the link goes (e.g. `/usr/local/bin/guesswho`).
    ///   - completion: called on the MAIN thread; nil on success, else the
    ///     failure (including the user cancelling the auth panel —
    ///     `NSOSStatusErrorDomain -60006` or `NSCocoaErrorDomain
    ///     NSUserCancelledError`, which callers should treat as a quiet
    ///     no-op, not an error alert).
    func installCommandLine(
        targetPath: String,
        symlinkPath: String,
        completion: @escaping (NSError?) -> Void
    )
}
