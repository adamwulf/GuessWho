// GuessWhoAppKitBridge.swift
// The native-macOS implementation of `AppKitPlugin`. Compiled ONLY into the
// GuessWhoAppKitBridge bundle target, which builds against the macOS SDK
// (SDKROOT=macosx), so `import AppKit` is legal here even though the Catalyst
// app can't link AppKit itself.
//
// The bundle's Info.plist NSPrincipalClass must be the Swift-mangled
// `<module>.<class>` string. With GENERATE_INFOPLIST_FILE=YES the module name
// defaults to PRODUCT_BUNDLE_IDENTIFIER, so NSPrincipalClass =
// `com.milestonemade.GuessWhoAppKitBridge.GuessWhoAppKitBridge`
// (see INFOPLIST_KEY_NSPrincipalClass in GuessWhoAppKitBridge-Shared.xcconfig).
// If that string and this class name ever drift apart, `bundle.principalClass`
// resolves to nil and the loader silently finds no plugin.

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
}
