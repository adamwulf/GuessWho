// AppKitBridgeLoader.swift
// Loads the native-macOS GuessWhoAppKitBridge bundle into the Catalyst
// process and vends its `AppKitPlugin` principal class, so app code can drive
// a real `NSOpenPanel` without ever naming an AppKit type. See
// `AppKitPlugin.swift` for the boundary contract and the bundle's own source
// for why Catalyst needs this at all.
//
// The bridge is a Mac-only affordance: on plain iOS/iPadOS the bundle isn't
// embedded (its Embed phase is `platformFilter = maccatalyst`), so `shared`
// is nil there and callers must fall back (the app keeps the PhotosPicker
// path on iOS — see ContactDetailView's PhotoChangeModifier).

import Foundation
import GuessWhoLogging

// Main-actor isolated: the panel driver is only ever loaded and called from
// SwiftUI view code on the main thread (NSOpenPanel must be driven on main),
// so the cached `shared` instance never crosses threads. This also satisfies
// Swift 6's concurrency checker for the non-Sendable `AppKitPlugin` static.
@MainActor
enum AppKitBridgeLoader {
    /// The bundle product name embedded under `<App>.app/Contents/PlugIns/`.
    private static let bundleFileName = "GuessWhoAppKitBridge.bundle"

    private static let log = GuessWhoLog.logger("app.appkitbridge")

    #if targetEnvironment(macCatalyst)
    /// The loaded panel driver, or nil if the bundle couldn't be loaded.
    /// Cached: the bundle loads once and the driver is reused.
    static let shared: AppKitPlugin? = loadPlugin()

    private static func loadPlugin() -> AppKitPlugin? {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
            log.error("AppKitBridge: no builtInPlugInsURL")
            return nil
        }
        let bundleURL = pluginsURL.appendingPathComponent(bundleFileName)
        guard let bundle = Bundle(url: bundleURL) else {
            log.error("AppKitBridge: no bundle at \(bundleURL.path)")
            return nil
        }
        // Accessing principalClass implicitly loads the bundle's code. A nil
        // here almost always means the NSPrincipalClass Info.plist string
        // doesn't match the Swift-mangled <module>.<class> name.
        guard let pluginClass = bundle.principalClass as? AppKitPlugin.Type else {
            log.error("AppKitBridge: principalClass is not an AppKitPlugin (check NSPrincipalClass <module>.<class>)")
            return nil
        }
        log.info("AppKitBridge: loaded plugin from \(bundleURL.lastPathComponent)")
        return pluginClass.init()
    }
    #else
    /// Not a Mac-only affordance target: no bundle is embedded, so there is
    /// no panel driver. Callers fall back to the platform's own picker.
    static let shared: AppKitPlugin? = nil
    #endif
}
