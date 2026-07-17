import Foundation

/// The four states `/usr/local/bin/guesswho` can be in, as the Preferences
/// pane's install section needs to distinguish them (plans/cli-mcp.md
/// Phase 3; mirrors Muse's shipped `CLISymlinkResolver` near-verbatim).
///
/// These names are INTERNAL discriminators — the user-facing rendering is
/// only the plain-language `InstallStrings` copy in GuessWhoMCPWire.
public enum CLISymlinkState: String, Sendable, Equatable {
    /// Nothing exists at the path.
    case notInstalled
    /// A REAL file/dir occupies the path, or a symlink points at a
    /// different (older / other-channel) bundle. Never clobber it — the
    /// user removes it via the copy-removal-command affordance.
    case conflictingFile
    /// A symlink whose destination is gone (the app moved or was
    /// updated in place). Offer reinstall-to-repair.
    case dangling
    /// A symlink whose destination exists AND resolves to OUR bundle.
    case installed
}

/// Wire-free status value the resolver returns. Host-side only — never
/// serialized onto the relay↔app channel.
public struct CLIInstallStatus: Sendable, Equatable {
    public let state: CLISymlinkState
    /// Resolved target if the symlink exists, else nil.
    /// - `.installed` → the bundle's guesswho-cli path.
    /// - `.dangling` / `.conflictingFile` → the actual destination
    ///   (so the UI can show "what's there if not us").
    public let target: String?
    /// Path of the symlink itself ("/usr/local/bin/guesswho").
    public let symlinkPath: String

    public init(state: CLISymlinkState, target: String?, symlinkPath: String) {
        self.state = state
        self.target = target
        self.symlinkPath = symlinkPath
    }
}

/// Pure-function helper that inspects `/usr/local/bin/guesswho` and returns
/// a `CLIInstallStatus`. Lives in the dispatch core (not the app) so the
/// four-state logic is unit-testable under plain `swift test`; the app
/// passes `CLIHelper.helperURL` as the expected target (the single locator —
/// never string-build the `Contents/MacOS/…` path).
public enum CLISymlinkResolver {

    /// Production symlink path. The link is named `guesswho` (the terminal
    /// command), pointing at the embedded `guesswho-cli` helper — the helper
    /// binary itself can't be named `guesswho` (case-insensitive APFS
    /// collision with the app executable `GuessWho`; see CLIHelper).
    public static let symlinkPath = "/usr/local/bin/guesswho"

    /// `symlinkPath` is the path being inspected; `expectedTargetPath` is
    /// what we expect a GuessWho-installed symlink to point at (after
    /// `resolvingSymlinksInPath()`). Pass nil to disable the "is this our
    /// bundle" check (useful for tests that just want to distinguish
    /// dangling vs non-dangling).
    ///
    /// Failure modes that can't be distinguished from "not installed"
    /// surface as `.notInstalled`: missing parent directory (rare, but
    /// possible if /usr/local/bin doesn't exist on a fresh macOS install
    /// without Xcode CLI tools), and EACCES on traversal (the sandbox
    /// shouldn't actually block read access to /usr/local/bin, but we'd
    /// rather surface "not installed" than error out — install will
    /// then fail with a clearer error from createSymbolicLink).
    public static func resolve(
        symlinkPath: String = CLISymlinkResolver.symlinkPath,
        expectedTargetPath: String?
    ) -> CLIInstallStatus {
        let fm = FileManager.default

        // `attributesOfItem(atPath:)` follows symlinks for FILE attributes
        // but reports the symlink's TYPE if the link itself exists at the
        // path — i.e. for a working symlink we get the target's regular-
        // file metadata; for a broken (dangling) symlink we get an error
        // because the target can't be stat'd. So we use this:
        //   - .destinationOfSymbolicLink succeeds iff the path IS a symlink
        //     (regardless of whether the destination exists). This is the
        //     authoritative is-symlink check, dangling included.
        //   - .fileExists(atPath:) follows the link; nonexistent OR broken
        //     symlink both return false; existing target returns true.
        // Together they discriminate all four states without false negatives.
        let symlinkDestination = try? fm.destinationOfSymbolicLink(atPath: symlinkPath)

        guard let dest = symlinkDestination else {
            // Either nothing exists at the path, OR a regular file does.
            // We need to distinguish: if a real file exists, that's a conflict.
            // `fileExists` follows symlinks; combined with not-a-symlink it
            // reports whether a regular file/directory occupies the path.
            if fm.fileExists(atPath: symlinkPath) {
                return CLIInstallStatus(
                    state: .conflictingFile,
                    target: symlinkPath,
                    symlinkPath: symlinkPath
                )
            }
            return CLIInstallStatus(state: .notInstalled, target: nil, symlinkPath: symlinkPath)
        }

        // We have a symlink. Two questions: does its destination exist
        // (else dangling), and does the resolved destination match our
        // bundle (else conflict).
        //
        // A relative destination (`ln -s ../foo guesswho`) is resolved
        // against the symlink's own directory before the existence check —
        // `fileExists` on the raw relative string would consult the
        // PROCESS's cwd and misreport.
        let absoluteDest: String
        if dest.hasPrefix("/") {
            absoluteDest = dest
        } else {
            absoluteDest = URL(fileURLWithPath: symlinkPath)
                .deletingLastPathComponent()
                .appendingPathComponent(dest).path
        }
        guard fm.fileExists(atPath: absoluteDest) else {
            return CLIInstallStatus(state: .dangling, target: dest, symlinkPath: symlinkPath)
        }

        guard let expectedTargetPath else {
            // Caller doesn't care about bundle identity; treat any
            // non-dangling symlink as installed. (Test-only path.)
            return CLIInstallStatus(state: .installed, target: dest, symlinkPath: symlinkPath)
        }

        // Compare resolved-symlink paths ON BOTH SIDES — load-bearing:
        // Setapp / Sparkle bundle paths contain symlinks themselves, so a
        // raw string compare false-negatives a legit install; and a symlink
        // pointing at a DIFFERENT (older / other-channel) bundle must
        // surface as a conflict, not silently talk to the wrong app.
        let resolvedDest = URL(fileURLWithPath: absoluteDest).resolvingSymlinksInPath().path
        let resolvedExpected = URL(fileURLWithPath: expectedTargetPath).resolvingSymlinksInPath().path
        if resolvedDest == resolvedExpected {
            return CLIInstallStatus(state: .installed, target: dest, symlinkPath: symlinkPath)
        }
        return CLIInstallStatus(state: .conflictingFile, target: dest, symlinkPath: symlinkPath)
    }

    /// The exact removal command the "Copy Removal Command" button puts on
    /// the pasteboard — mirroring copy-path, the user pastes it rather than
    /// hand-typing a path (plans/cli-mcp.md Phase 3: uninstall is not a
    /// raw-terminal dead end). There is no authorized-delete counterpart to
    /// `NSWorkspaceAuthorizationType.createSymbolicLink`, so removal is a
    /// paste-into-Terminal step by construction.
    public static func removalCommand(symlinkPath: String = CLISymlinkResolver.symlinkPath) -> String {
        "rm \(shellEscape(symlinkPath))"
    }

    /// Single-quote shell escaping for paths embedded in copyable commands.
    public static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
