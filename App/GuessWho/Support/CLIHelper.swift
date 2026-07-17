import Foundation

/// The embedded relay CLI (`GuessWho.app/Contents/MacOS/guesswho-cli`) and the
/// App Group it shares with the app (plans/cli-mcp.md).
enum CLIHelper {
    /// THE one place the helper's on-disk location is derived (the
    /// Muse-verified pattern): `forAuxiliaryExecutable` resolves to
    /// `Contents/MacOS/<name>` on Catalyst. Every future call site
    /// (preferences pane, symlink installer/status) must go through this —
    /// never string-build the `Contents/MacOS/...` path.
    ///
    /// The name is `guesswho-cli`, NOT `guesswho`: on case-insensitive APFS a
    /// helper named `guesswho` would be the same directory entry as the app
    /// executable `GuessWho`, and this call would resolve to the app binary.
    static var helperURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "guesswho-cli")
    }

    /// The CLI/MCP App Group id, resolved from the `GuessWhoCLIAppGroup`
    /// Info.plist key (fed by `GUESSWHO_CLI_APP_GROUP` in
    /// Config/CLIAppGroup-*.xcconfig). The helper reads the same key from its
    /// own embedded Info.plist, and both entitlements expand the same build
    /// var, so app and helper always agree per channel (INV-4). Distinct from
    /// `AppGroup.id` (the storage/extension group): this group exists for the
    /// app↔CLI seam and is channel-suffixed (`.debug` in Debug).
    ///
    /// `nil` (rather than a literal fallback) when the key is missing/empty:
    /// there is no safe hardcoded default for a per-channel id, and the only
    /// Phase 0 consumer (the diagnostic listener) treats nil as
    /// "wiring broken — log and bail".
    static let appGroupID: String? =
        (Bundle.main.object(forInfoDictionaryKey: "GuessWhoCLIAppGroup") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
}
