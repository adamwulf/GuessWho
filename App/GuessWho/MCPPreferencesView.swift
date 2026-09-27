#if targetEnvironment(macCatalyst)

import SwiftUI
import UIKit
import EventKit
import GuessWhoLogging
import GuessWhoMCPCore
import GuessWhoMCPWire
import GuessWhoSync

/// The app's Settings sheet (⌘, on Catalyst — plans/cli-mcp.md Phase 3),
/// laid out as preference tabs (`PreferencesTab`):
///
/// - **Access** — the assistant/terminal access modes (App-Group defaults —
///   the SAME keys `MCPHostController` observes and `MCPGates` reads per
///   call, so a flip applies immediately) and the command-line install
///   (copy-path primary install, the 4-state status from
///   `CLISymlinkResolver`, the admin-auth symlink install via the AppKit
///   bridge, and paste-able removal — never a hand-typed path).
/// - **Agent Activity** — the agent-activity log, reloaded on each visit.
/// - **Calendars** — which calendars feed the Events section
///   (`CalendarsPreferencesPane`, backed by the shared
///   `CalendarVisibilitySettings`).
/// - **Recently Deleted** — `RecentlyDeletedView`, reloaded on each visit.
/// - **Advanced** — the Debug Mode toggle (kept here so taking over ⌘,
///   loses nothing vs. the Settings.bundle window it replaces — iOS still
///   uses Settings.bundle).
///
/// Every CLI/MCP-facing string comes from the wire module's
/// `PreferencesStrings` / `InstallStrings` / `AgentActivityStrings` /
/// `RecentlyDeletedStrings`, all under the banned-vocabulary test. The
/// Advanced tab's Debug Mode copy is a sanctioned debug-mode surface
/// (product principle carve-out) and may use internal vocabulary.
struct MCPPreferencesView: View {
    @ObservedObject var installModel: CLIInstallModel
    let auditLog: MCPAuditLog
    let recentlyDeleted: RecentlyDeletedService
    let service: SyncService
    let calendarVisibility: CalendarVisibilitySettings

    @AppStorage(MCPToggleKeys.mcpAccessMode, store: MCPPreferencesStore.group)
    private var mcpAccess: MCPAccessMode = .off
    @AppStorage(MCPToggleKeys.cliAccessMode, store: MCPPreferencesStore.group)
    private var cliAccess: MCPAccessMode = .off
    @AppStorage(AppSettings.Key.debugModeEnabled)
    private var debugModeEnabled = AppSettings.Default.debugModeEnabled

    @State private var selectedTab: PreferencesTab = .access
    @State private var activityRows: [AgentActivityRow] = []
    @State private var activityLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PreferencesTabBar(selection: $selectedTab)
                    .padding(.vertical, 8)
                Divider()
                selectedPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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

    // MARK: - Tabs

    /// Only the selected pane exists, so each pane's `.task` runs again when
    /// the user returns to it — the install status, agent activity, calendar
    /// list, and recently deleted items are fresh on every visit.
    @ViewBuilder
    private var selectedPane: some View {
        switch selectedTab {
        case .access:
            Form {
                assistantSection
                terminalSection
                installSection
            }
            .task { installModel.refresh() }
        case .activity:
            Form {
                activitySection
            }
            .task { await loadActivity() }
        case .calendars:
            CalendarsPreferencesPane(service: service, visibility: calendarVisibility)
        case .recentlyDeleted:
            RecentlyDeletedView(service: recentlyDeleted)
        case .advanced:
            Form {
                debugSection
            }
        }
    }

    // MARK: - Access modes (one tri-state per surface, Allume-style)

    private var assistantSection: some View {
        Section {
            accessModePicker(selection: $mcpAccess)
        } header: {
            Text(PreferencesStrings.mcpSectionTitle)
        } footer: {
            Text(Self.mcpDescription(for: mcpAccess))
        }
    }

    private var terminalSection: some View {
        Section {
            accessModePicker(selection: $cliAccess)
        } header: {
            Text(PreferencesStrings.cliSectionTitle)
        } footer: {
            Text(Self.cliDescription(for: cliAccess))
        }
    }

    private func accessModePicker(selection: Binding<MCPAccessMode>) -> some View {
        Picker(PreferencesStrings.accessModeLabel, selection: selection) {
            Text(PreferencesStrings.accessModeOff).tag(MCPAccessMode.off)
            Text(PreferencesStrings.accessModeReadOnly).tag(MCPAccessMode.readOnly)
            Text(PreferencesStrings.accessModeReadWrite).tag(MCPAccessMode.readWrite)
        }
        .pickerStyle(.segmented)
    }

    private static func mcpDescription(for mode: MCPAccessMode) -> String {
        switch mode {
        case .off: return PreferencesStrings.mcpOffDescription
        case .readOnly: return PreferencesStrings.mcpReadOnlyDescription
        case .readWrite: return PreferencesStrings.mcpReadWriteDescription
        }
    }

    private static func cliDescription(for mode: MCPAccessMode) -> String {
        switch mode {
        case .off: return PreferencesStrings.cliOffDescription
        case .readOnly: return PreferencesStrings.cliReadOnlyDescription
        case .readWrite: return PreferencesStrings.cliReadWriteDescription
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
        } footer: {
            // No header: the tab already names the pane.
            Text(AgentActivityStrings.footer)
        }
    }

    /// Keeps the previous rows on screen while a revisit reloads, so the
    /// pane doesn't flash back to a spinner.
    private func loadActivity() async {
        activityRows = AgentActivityFormatter.rows(from: await auditLog.entries(), limit: 20)
        activityLoaded = true
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

// MARK: - Tabs

/// The Settings sheet's tabs, in display order.
enum PreferencesTab: CaseIterable, Identifiable {
    case access
    case activity
    case calendars
    case recentlyDeleted
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .access: return "Access"
        case .activity: return AgentActivityStrings.sectionTitle
        case .calendars: return "Calendars"
        case .recentlyDeleted: return RecentlyDeletedStrings.title
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .access: return "key"
        case .activity: return "clock.arrow.circlepath"
        case .calendars: return "calendar"
        case .recentlyDeleted: return "trash"
        case .advanced: return "gearshape.2"
        }
    }
}

/// A Mac-style preferences toolbar: one icon-over-title button per tab,
/// centered, with the selected tab tinted. When the sheet is too narrow to
/// show every tab, the row scrolls sideways instead of clipping.
private struct PreferencesTabBar: View {
    @Binding var selection: PreferencesTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabButtons
                .padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                tabButtons
                    .padding(.horizontal, 12)
            }
        }
    }

    private var tabButtons: some View {
        HStack(spacing: 4) {
            ForEach(PreferencesTab.allCases) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: PreferencesTab) -> some View {
        let isSelected = tab == selection
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.title3)
                    .frame(height: 24)
                    // The title alone names the tab for VoiceOver.
                    .accessibilityHidden(true)
                Text(tab.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 72)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(shape.fill(isSelected ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Calendars

/// The Calendars tab: which calendars feed the main Events section, grouped
/// by account, with a switch per account and per calendar. Lists
/// `SyncService.availableEventCalendars()` and reads/writes the SAME
/// `CalendarVisibilitySettings` instance `EventsRepository` filters with, so
/// each switch applies to an open Events list immediately. Every calendar
/// is visible until the user hides it. Related events on person,
/// organization, or place pages don't go through that filter, which the
/// pane's description says.
private struct CalendarsPreferencesPane: View {
    let service: SyncService
    let visibility: CalendarVisibilitySettings

    @State private var accounts: [CalendarAccountGroup] = []
    @State private var loaded = false
    @State private var loadFailed = false

    var body: some View {
        content
            // Keyed on access so a grant that lands while the sheet is open
            // (the launch-time request resolving) loads the list.
            .task(id: service.eventsAuthorization) { reload() }
            // Calendar.app and account sync can add, remove, or rename a
            // calendar while this pane stays selected. Keep its controls in
            // step with the same store-change signal the Events list observes.
            .onReceive(
                NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                reload()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch service.eventsAuthorization {
        case .notDetermined:
            ProgressView()
        case .denied:
            ContentUnavailableView {
                Label("Calendar Access Is Off", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("To choose which calendars appear in Events, allow calendar access in System Settings › Privacy & Security › Calendars.")
            }
        case .restricted:
            ContentUnavailableView {
                Label("Calendar Access Is Restricted", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("This Mac's settings don't allow calendar access, so calendars can't be listed here.")
            }
        case .authorized:
            if !loaded {
                ProgressView()
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Calendars Couldn’t Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The calendar list couldn’t be read.")
                } actions: {
                    Button("Try Again", action: reload)
                }
            } else if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Calendars", systemImage: "calendar")
                } description: {
                    Text("When you add a calendar, it appears here.")
                }
            } else {
                calendarForm
            }
        }
    }

    private var calendarForm: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose which calendars appear in Events.")
                    Text("Pages for people, organizations, and places still show their related events from every calendar. New calendars are shown automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(accounts) { account in
                Section {
                    accountToggle(account)
                    ForEach(account.calendars) { calendar in
                        calendarToggle(calendar)
                    }
                }
            }
        }
    }

    /// On only when every calendar in the account is shown; a partly-shown
    /// account reads off (its caption gives the count), and switching it on
    /// shows them all.
    private func accountToggle(_ account: CalendarAccountGroup) -> some View {
        let shown = account.calendars.filter { visibility.isVisible(calendarID: $0.id) }.count
        let isOn = Binding(
            get: { account.calendars.allSatisfy { visibility.isVisible(calendarID: $0.id) } },
            set: { newValue in
                visibility.setVisible(newValue, calendarIDs: account.calendars.map(\.id))
            })
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title)
                    .font(.headline)
                Text(Self.summary(shown: shown, total: account.calendars.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func calendarToggle(_ calendar: EventCalendar) -> some View {
        let isOn = Binding(
            get: { visibility.isVisible(calendarID: calendar.id) },
            set: { visibility.setVisible($0, calendarID: calendar.id) })
        return Toggle(isOn: isOn) {
            Label {
                Text(calendar.title.isEmpty ? "Untitled Calendar" : calendar.title)
            } icon: {
                Circle()
                    .fill(Self.color(for: calendar))
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.leading, 12)
    }

    private func reload() {
        guard service.eventsAuthorization == .authorized else { return }
        do {
            accounts = CalendarAccountGroup.groups(from: try service.availableEventCalendars())
            loadFailed = false
        } catch {
            accounts = []
            loadFailed = true
        }
        loaded = true
    }

    private static func summary(shown: Int, total: Int) -> String {
        if shown == 0 { return "Hidden from Events" }
        if shown == total { return total == 1 ? "Shown in Events" : "All \(total) calendars shown" }
        return "\(shown) of \(total) calendars shown"
    }

    private static func color(for calendar: EventCalendar) -> Color {
        calendar.colorHex.flatMap(UIColor.init(hexString:)).map(Color.init(uiColor:)) ?? .secondary
    }
}

/// One account's calendars for the Calendars tab. `groups(from:)` groups by
/// account identity (`EventCalendar.sourceID`), not display name, so two
/// accounts that share a name stay separate. Accounts, and the calendars
/// within each, sort by name with the identifier as the tie-breaker, so the
/// list keeps one stable order across reloads.
struct CalendarAccountGroup: Identifiable {
    /// The account identifier; empty for calendars listed without an account.
    let id: String
    let title: String
    let calendars: [EventCalendar]

    static func groups(from calendars: [EventCalendar]) -> [CalendarAccountGroup] {
        Dictionary(grouping: calendars, by: \.sourceID)
            .map { sourceID, members in
                let sorted = members.sorted { precedes($0.title, $0.id, $1.title, $1.id) }
                // Every calendar in an account carries the account's name.
                let title = sorted.first { !$0.sourceTitle.isEmpty }?.sourceTitle ?? "Other"
                return CalendarAccountGroup(id: sourceID, title: title, calendars: sorted)
            }
            .sorted { precedes($0.title, $0.id, $1.title, $1.id) }
    }

    private static func precedes(
        _ lhsName: String, _ lhsID: String, _ rhsName: String, _ rhsID: String
    ) -> Bool {
        switch lhsName.localizedStandardCompare(rhsName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhsID < rhsID
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
    /// The one hosting type both the presentation and the duplicate check
    /// use, so they can't drift apart if the root view's type changes.
    private typealias SettingsHost = UIHostingController<MCPPreferencesView>

    private static let installModel = CLIInstallModel()

    /// Desktop-sized, so each tab has room without scrolling in a typical
    /// window; `sheetSize(fitting:)` shrinks it to fit a smaller window.
    private static let preferredSheetSize = CGSize(width: 680, height: 600)
    private static let minimumSheetSize = CGSize(width: 420, height: 360)
    private static let windowMargin: CGFloat = 40

    static func present() {
        let windows = applicationWindows()
        if let owner = windows.first(where: { window in
            window.rootViewController.map(containsSettingsHost) ?? false
        }) {
            // Settings is app-global. If another Catalyst window invoked ⌘,
            // bring forward the scene that already owns the sheet instead of
            // silently doing nothing or stacking a second copy.
            if let scene = owner.windowScene {
                UIApplication.shared.requestSceneSessionActivation(
                    scene.session,
                    userActivity: nil,
                    options: nil,
                    errorHandler: nil
                )
            }
            return
        }
        let roots = windows.compactMap(\.rootViewController)
        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate,
              let root = roots.first
        else { return }

        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let view = MCPPreferencesView(
            installModel: installModel,
            auditLog: appDelegate.mcpHostController.auditLog,
            recentlyDeleted: appDelegate.mcpHostController.makeRecentlyDeletedService(),
            service: appDelegate.service,
            calendarVisibility: appDelegate.calendarVisibility)
        let host = SettingsHost(rootView: view)
        host.modalPresentationStyle = .formSheet
        host.preferredContentSize = sheetSize(fitting: presenter.view.window?.bounds.size)
        presenter.present(host, animated: true)
    }

    /// The preferred size, shrunk to leave a margin inside a smaller window
    /// but never below a floor the tabs stay usable at (each pane scrolls).
    private static func sheetSize(fitting windowSize: CGSize?) -> CGSize {
        guard let windowSize else { return preferredSheetSize }
        return CGSize(
            width: min(
                preferredSheetSize.width,
                max(windowSize.width - windowMargin * 2, minimumSheetSize.width)),
            height: min(
                preferredSheetSize.height,
                max(windowSize.height - windowMargin * 2, minimumSheetSize.height)))
    }

    /// Windows ordered with the frontmost Catalyst window first, followed by
    /// the other active windows and then inactive scenes. The complete list is
    /// also the scope of the duplicate-sheet lookup above.
    private static func applicationWindows() -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeWindows = scenes
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
        let otherWindows = scenes
            .filter { $0.activationState != .foregroundActive }
            .flatMap(\.windows)
        let orderedWindows = activeWindows.filter(\.isKeyWindow)
            + activeWindows.filter { !$0.isKeyWindow }
            + otherWindows.filter(\.isKeyWindow)
            + otherWindows.filter { !$0.isKeyWindow }
        return orderedWindows
    }

    private static func containsSettingsHost(_ root: UIViewController) -> Bool {
        var candidate: UIViewController? = root
        while let current = candidate {
            if current is SettingsHost { return true }
            candidate = current.presentedViewController
        }
        return false
    }
}

#endif
