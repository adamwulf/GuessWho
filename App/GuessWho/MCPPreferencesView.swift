#if targetEnvironment(macCatalyst)

import SwiftUI
import UIKit
import GuessWhoLogging
import GuessWhoMCPCore
import GuessWhoMCPWire

/// The app's Settings sheet (⌘, on Catalyst — plans/cli-mcp.md Phase 3).
///
/// Sections: the assistant/terminal master toggles + read-only toggles
/// (App-Group defaults — the SAME keys `MCPHostController` observes and
/// `MCPGates` reads per call, so a flip applies immediately); the
/// command-line install section (copy-path primary install, the 4-state
/// status from `CLISymlinkResolver`, the admin-auth symlink install via the
/// AppKit bridge, and paste-able removal — never a hand-typed path); the
/// agent-activity log; the Recently Deleted entry point; and the Debug Mode
/// toggle (kept here so taking over ⌘, loses nothing vs. the
/// Settings.bundle window it replaces — iOS still uses Settings.bundle).
///
/// Every CLI/MCP-facing string comes from the wire module's
/// `PreferencesStrings` / `InstallStrings` / `AgentActivityStrings` /
/// `RecentlyDeletedStrings`, all under the banned-vocabulary test. The
/// Debug section is a sanctioned debug-mode surface (product principle
/// carve-out) and may use internal vocabulary.
struct MCPPreferencesView: View {
    @ObservedObject var installModel: CLIInstallModel
    let auditLog: MCPAuditLog
    let recentlyDeleted: RecentlyDeletedService

    @AppStorage(MCPToggleKeys.isMCPEnabled, store: MCPPreferencesStore.group)
    private var isMCPEnabled = false
    @AppStorage(MCPToggleKeys.isMCPReadOnly, store: MCPPreferencesStore.group)
    private var isMCPReadOnly = true
    @AppStorage(MCPToggleKeys.isCLIEnabled, store: MCPPreferencesStore.group)
    private var isCLIEnabled = false
    @AppStorage(MCPToggleKeys.isCLIReadOnly, store: MCPPreferencesStore.group)
    private var isCLIReadOnly = true
    @AppStorage(AppSettings.Key.debugModeEnabled)
    private var debugModeEnabled = AppSettings.Default.debugModeEnabled

    @State private var activityRows: [AgentActivityRow] = []
    @State private var activityLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                assistantSection
                terminalSection
                installSection
                activitySection
                recentlyDeletedSection
                debugSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                installModel.refresh()
                activityRows = AgentActivityFormatter.rows(from: await auditLog.entries(), limit: 20)
                activityLoaded = true
            }
            .alert(
                installModel.alertTitle,
                isPresented: $installModel.showsAlert,
                actions: { Button("OK", role: .cancel) {} },
                message: {
                    if !installModel.alertMessage.isEmpty {
                        Text(installModel.alertMessage)
                    }
                })
        }
    }

    // MARK: - Toggles

    private var assistantSection: some View {
        Section {
            Toggle(PreferencesStrings.mcpToggleTitle, isOn: $isMCPEnabled)
            Toggle(PreferencesStrings.mcpReadOnlyTitle, isOn: $isMCPReadOnly)
                .disabled(!isMCPEnabled)
        } footer: {
            Text(PreferencesStrings.mcpToggleFooter)
        }
    }

    private var terminalSection: some View {
        Section {
            Toggle(PreferencesStrings.cliToggleTitle, isOn: $isCLIEnabled)
            Toggle(PreferencesStrings.cliReadOnlyTitle, isOn: $isCLIReadOnly)
                .disabled(!isCLIEnabled)
        } footer: {
            Text(PreferencesStrings.cliToggleFooter + "\n\n" + PreferencesStrings.readOnlyFooter)
        }
    }

    // MARK: - Command-line install

    private var installSection: some View {
        Section {
            statusRow

            if installModel.showsRepairHint {
                Label(InstallStrings.repairHint, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            // Copy-path: the PRIMARY install on every channel. The user
            // pastes the absolute helper path into their assistant's
            // settings; nothing is generated or written on their behalf.
            VStack(alignment: .leading, spacing: 6) {
                Text(InstallStrings.helperPathCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(installModel.helperPath ?? InstallStrings.helperMissing)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Button {
                    installModel.copyHelperPath()
                } label: {
                    copyLabel(InstallStrings.copyPathButton, copied: installModel.copiedItem == .path)
                }
                .disabled(installModel.helperPath == nil)
            }
            .padding(.vertical, 2)

            perStateActions

            if installModel.status.state != .notInstalled {
                removalRow
            }
        } header: {
            Text(InstallStrings.sectionTitle)
        }
    }

    private var statusRow: some View {
        let (text, icon, tint): (String, String, Color) = {
            switch installModel.status.state {
            case .installed:
                return (InstallStrings.statusInstalled, "checkmark.circle.fill", .green)
            case .notInstalled:
                return (InstallStrings.statusNotInstalled, "terminal", .secondary)
            case .dangling:
                return (InstallStrings.statusDangling, "exclamationmark.triangle.fill", .orange)
            case .conflictingFile:
                return (InstallStrings.statusConflict, "exclamationmark.triangle.fill", .orange)
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: icon)
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
            if installModel.status.state == .installed {
                Text(InstallStrings.installedDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var perStateActions: some View {
        switch installModel.status.state {
        case .notInstalled:
            Button(InstallStrings.installButton) { installModel.install() }
                .disabled(installModel.isInstalling)
        case .dangling:
            Button(InstallStrings.reinstallButton) { installModel.install() }
                .disabled(installModel.isInstalling)
        case .conflictingFile:
            Button(InstallStrings.revealConflictButton) { installModel.revealConflictInFinder() }
        case .installed:
            EmptyView()
        }
    }

    /// Uninstall (and clearing a broken or conflicting install) is never a
    /// hand-typed path: the exact removal command goes on the pasteboard.
    private var removalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(InstallStrings.removalCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(installModel.removalCommand)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Button {
                installModel.copyRemovalCommand()
            } label: {
                copyLabel(InstallStrings.copyRemovalButton, copied: installModel.copiedItem == .removal)
            }
        }
        .padding(.vertical, 2)
    }

    private func copyLabel(_ title: String, copied: Bool) -> some View {
        Label(
            copied ? InstallStrings.copiedConfirmation : title,
            systemImage: copied ? "checkmark" : "doc.on.doc")
    }

    // MARK: - Agent activity

    private var activitySection: some View {
        Section {
            if !activityLoaded {
                ProgressView()
            } else if activityRows.isEmpty {
                Text(AgentActivityStrings.emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activityRows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(row.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 1)
                }
            }
        } header: {
            Text(AgentActivityStrings.sectionTitle)
        } footer: {
            Text(AgentActivityStrings.footer)
        }
    }

    // MARK: - Recently Deleted

    private var recentlyDeletedSection: some View {
        Section {
            NavigationLink(RecentlyDeletedStrings.title) {
                RecentlyDeletedView(service: recentlyDeleted)
            }
        }
    }

    // MARK: - Debug (sanctioned debug-mode surface; internal vocabulary OK)

    private var debugSection: some View {
        Section {
            Toggle("Debug Mode", isOn: $debugModeEnabled)
        } footer: {
            // Mirrors the Settings.bundle footer so Catalyst (where this
            // sheet replaces the auto-rendered ⌘, window) reads the same.
            Text("Shows developer diagnostics like the GuessWho reconcile indicator on contact rows and the Debug section on contact details.")
        }
    }
}

/// The shared-container defaults the toggles live in — the SAME suite
/// `MCPHostController` observes and `MCPGates` reads, resolved once.
/// `.standard` fallback only when the App Group wiring is broken (the host
/// can't start then either; the error is logged at bootstrap).
enum MCPPreferencesStore {
    /// `nonisolated(unsafe)` is sound: UserDefaults is documented
    /// thread-safe, and this is a write-once `let`.
    nonisolated(unsafe) static let group: UserDefaults =
        CLIHelper.appGroupID.flatMap { UserDefaults(suiteName: $0) } ?? .standard
}

/// Backing model for the install section: the resolver status, the copy
/// actions, the admin-auth install via the AppKit bridge, and the
/// stale-location repair hint.
@MainActor
final class CLIInstallModel: ObservableObject {
    /// Group-defaults key recording the helper path the user last copied or
    /// installed — the app's only sandbox-reachable record of what their
    /// client configs point at. A mismatch with the CURRENT helper path
    /// means the app moved (MAS in-place update, user drag) and every
    /// pasted absolute path went stale → the repair hint. Internal key,
    /// never user-facing.
    private static let advertisedPathKey = "cliAdvertisedHelperPath"

    private static let log = GuessWhoLog.logger("app.mcp-preferences")

    enum CopiedItem { case path, removal }

    @Published private(set) var status = CLIInstallStatus(
        state: .notInstalled, target: nil, symlinkPath: CLISymlinkResolver.symlinkPath)
    @Published private(set) var showsRepairHint = false
    @Published private(set) var isInstalling = false
    /// Which copy button just fired, for the transient "Copied" flash.
    @Published private(set) var copiedItem: CopiedItem?
    @Published var showsAlert = false
    private(set) var alertTitle = ""
    private(set) var alertMessage = ""

    /// The single locator (CLIHelper.helperURL) — never string-built.
    let helperPath: String? = CLIHelper.helperURL?.path

    var removalCommand: String { CLISymlinkResolver.removalCommand() }

    // MARK: - Status

    func refresh() {
        status = CLISymlinkResolver.resolve(expectedTargetPath: helperPath)
        showsRepairHint = Self.isAdvertisedPathStale()
        Self.log.info("cli status", [
            "state": status.state.rawValue,
            "repairHint": showsRepairHint
        ])
    }

    /// True when the last path the user copied/installed no longer matches
    /// the shipped helper path (or no longer exists). Checked at launch for
    /// the breadcrumb and by `refresh()` for the Preferences hint.
    static func isAdvertisedPathStale() -> Bool {
        guard let advertised = MCPPreferencesStore.group.string(forKey: advertisedPathKey),
              let current = CLIHelper.helperURL?.path
        else { return false }
        return advertised != current
    }

    /// Launch-time verification (plans/cli-mcp.md Phase 3): confirm the
    /// shipped helper path resolves and note when previously-pasted client
    /// configs went stale. Log-only — the user-visible surface is the
    /// Preferences repair hint.
    static func verifyHelperAtLaunch() {
        if let helper = CLIHelper.helperURL?.path {
            if !FileManager.default.fileExists(atPath: helper) {
                log.error("embedded cli helper missing on disk", ["path": helper])
            }
        } else {
            log.error("embedded cli helper not found in bundle")
        }
        if isAdvertisedPathStale() {
            log.notice("helper path changed since last copy/install — client configs may be stale")
        }
    }

    private func stampAdvertisedPath() {
        guard let helperPath else { return }
        MCPPreferencesStore.group.set(helperPath, forKey: Self.advertisedPathKey)
        showsRepairHint = false
    }

    // MARK: - Copy actions

    func copyHelperPath() {
        guard let helperPath else { return }
        UIPasteboard.general.string = helperPath
        stampAdvertisedPath()
        flashCopied(.path)
        Self.log.info("copied helper path")
    }

    func copyRemovalCommand() {
        UIPasteboard.general.string = removalCommand
        flashCopied(.removal)
        Self.log.info("copied removal command")
    }

    private func flashCopied(_ item: CopiedItem) {
        copiedItem = item
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self?.copiedItem == item { self?.copiedItem = nil }
        }
    }

    // MARK: - Install

    func install() {
        guard let helperPath else {
            presentAlert(title: InstallStrings.installFailedTitle, message: InstallStrings.helperMissing)
            return
        }
        guard let plugin = AppKitBridgeLoader.shared else {
            // No bridge (packaging failure): the copy-path install above is
            // always available, so just say the panel path failed.
            Self.log.error("cli install failed: AppKit bridge unavailable")
            presentAlert(title: InstallStrings.installFailedTitle, message: "")
            return
        }
        // `createSymbolicLink` cannot replace an existing path (there is no
        // authorized-delete), so a dangling/conflicting occupant must be
        // removed first — the removal row handles that. Attempt anyway when
        // the user pressed Reinstall: they may have just cleared it, and
        // the failure alert below is honest if not.
        isInstalling = true
        Self.log.info("cli install attempt", ["target": helperPath])
        plugin.installCommandLine(
            targetPath: helperPath,
            symlinkPath: CLISymlinkResolver.symlinkPath
        ) { [weak self] error in
            guard let self else { return }
            self.isInstalling = false
            if let error {
                if Self.isUserCancelled(error) {
                    Self.log.info("cli install cancelled by user")
                } else {
                    Self.log.error("cli install failed", [
                        "domain": error.domain, "code": error.code,
                        "description": error.localizedDescription
                    ])
                    self.presentAlert(
                        title: InstallStrings.installFailedTitle,
                        message: error.localizedDescription)
                }
            } else {
                Self.log.notice("cli install succeeded")
                self.stampAdvertisedPath()
            }
            self.refresh()
        }
    }

    /// True iff `error` indicates the user dismissed the system auth panel.
    /// Two domains depending on macOS version / which layer caught it:
    /// `NSOSStatusErrorDomain -60006` (errAuthorizationCanceled) — the
    /// historical path — and `NSCocoaErrorDomain NSUserCancelledError`, the
    /// Cocoa-wrapped form recent macOS versions use. (Muse-shipped logic.)
    static func isUserCancelled(_ error: NSError) -> Bool {
        if error.domain == NSOSStatusErrorDomain && error.code == -60006 { return true }
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return true }
        return false
    }

    // MARK: - Conflict reveal

    /// "Show in Finder" for the conflicting-file state: opens the directory
    /// containing the occupant (the same `UIApplication.open`-a-folder
    /// mechanism DebugMenuActions uses — Catalyst hands folder URLs to
    /// Finder).
    func revealConflictInFinder() {
        let folder = URL(fileURLWithPath: status.symlinkPath)
            .deletingLastPathComponent()
        UIApplication.shared.open(folder, options: [:], completionHandler: nil)
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showsAlert = true
    }
}

/// Self-presenting entry point for the Settings… menu command (⌘,) — same
/// pattern as DebugMenuActions: resolve the frontmost view controller
/// directly so presentation never depends on responder-chain focus.
@MainActor
enum MCPPreferencesPresenter {
    private static let installModel = CLIInstallModel()

    static func present() {
        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate,
              let presenter = topViewController()
        else { return }
        // Already showing? Don't stack a second sheet on repeat ⌘,.
        if presenter is UIHostingController<MCPPreferencesView> { return }
        let view = MCPPreferencesView(
            installModel: installModel,
            auditLog: appDelegate.mcpHostController.auditLog,
            recentlyDeleted: appDelegate.mcpHostController.makeRecentlyDeletedService())
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        presenter.present(host, animated: true)
    }

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
}

#endif
