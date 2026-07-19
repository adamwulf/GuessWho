// GuessWhoAppKitBridge.swift
// The native-macOS implementation of `AppKitPlugin`. Compiled ONLY into the
// GuessWhoAppKitBridge bundle target, which builds against the macOS SDK
// (SDKROOT=macosx), so `import AppKit` is legal here even though the Catalyst
// app can't link AppKit itself.
//
// The bundle's Info.plist NSPrincipalClass must be the Swift-mangled
// `<module>.<class>` string — `Bundle.principalClass` looks up that mangled
// symbol in the bundle image (it does NOT go through the Obj-C flat name
// table, so the bare `@objc(...)` name alone won't do). Our Swift module name
// is PRODUCT_MODULE_NAME (= PRODUCT_NAME = TARGET_NAME = `GuessWhoAppKitBridge`,
// NOT the dotted bundle id), so the resolved NSPrincipalClass is
// `GuessWhoAppKitBridge.GuessWhoAppKitBridge`
// (set via INFOPLIST_KEY_NSPrincipalClass in GuessWhoAppKitBridge-Shared.xcconfig).
// If that string and this class/module name ever drift apart,
// `bundle.principalClass` resolves to nil and the loader silently finds no
// plugin.

import AppKit
import Foundation
import UniformTypeIdentifiers

@objc(GuessWhoAppKitBridge)
public final class GuessWhoAppKitBridge: NSObject, AppKitPlugin {
    override public required init() {
        super.init()
    }

    public func presentOpenPanel(
        allowedExtensions: [String],
        allowsMultiple: Bool,
        completion: @escaping ([URL]) -> Void
    ) {
        // Build AND run the panel on the main thread. `panel.begin` runs the
        // panel MODELESS and calls back on the main run loop — NOT
        // `runModal()`, which blocks the run loop and freezes Catalyst, and
        // NOT `beginSheetModal`, which needs an AppKit NSWindow we don't have
        // from Catalyst. Hop explicitly rather than assume we're on main.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = allowsMultiple
            panel.resolvesAliases = true
            if !allowedExtensions.isEmpty {
                panel.allowedContentTypes = allowedExtensions.compactMap {
                    UTType(filenameExtension: $0)
                }
            }
            panel.begin { response in
                guard response == .OK else {
                    completion([])
                    return
                }
                completion(panel.urls)
            }
        }
    }

    public func installCommandLine(
        targetPath: String,
        symlinkPath: String,
        completion: @escaping (NSError?) -> Void
    ) {
        // The Muse-shipped mechanism verbatim: the system admin-auth panel
        // vends a short-lived authorization, and a FileManager constructed
        // from it may create exactly the symlink the user approved. There
        // is no authorized-DELETE counterpart, so replacing an existing
        // path (conflict / broken-link states) stays a user-pasted `rm`.
        NSWorkspace().requestAuthorization(to: .createSymbolicLink) { auth, error in
            if let error = error {
                DispatchQueue.main.async { completion(error as NSError) }
                return
            }
            guard let auth = auth else {
                let unknown = NSError(
                    domain: "GuessWhoAppKitBridge",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Authorization unavailable"])
                DispatchQueue.main.async { completion(unknown) }
                return
            }
            let fm = FileManager(authorization: auth)
            do {
                try fm.createSymbolicLink(
                    at: URL(fileURLWithPath: symlinkPath),
                    withDestinationURL: URL(fileURLWithPath: targetPath))
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error as NSError) }
            }
        }
    }
}
