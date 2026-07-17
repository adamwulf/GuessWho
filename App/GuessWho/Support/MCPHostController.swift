#if targetEnvironment(macCatalyst)

import Foundation
import GuessWhoLogging
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPTransport
import GuessWhoMCPWire

/// Owns the app-side end of the CLI/MCP channel and binds its lifecycle to
/// the master toggles in the shared-container defaults (plans/cli-mcp.md
/// Phase 1; lifecycle state machine mirrors the shipped Muse controller).
///
/// INV-2b: this controller INJECTS the app's live `ContactsRepository` /
/// `SyncService` into the dispatch core — it never constructs a store of
/// its own. The channel runs whenever either surface is enabled;
/// per-origin and per-permission gating happens per call inside
/// `ToolDispatcher`.
@MainActor
final class MCPHostController: NSObject {
    private enum State {
        case stopped
        case starting
        case running
        case stopping
    }

    private static let log = GuessWhoLog.logger("app.mcp-host")

    private let service: SyncService
    private let repository: ContactsRepository
    private var state: State = .stopped
    private var host: MCPPipeHost?
    private var observerInstalled = false
    private var isShuttingDown = false
    /// KVO context — a unique stable address. `nonisolated(unsafe)` is
    /// sound: the pointer is allocated once, never written through, and
    /// compared by address only (KVO callbacks arrive on arbitrary
    /// threads).
    private nonisolated(unsafe) static let kvoContext = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    private var groupDefaults: UserDefaults? {
        CLIHelper.appGroupID.flatMap { UserDefaults(suiteName: $0) }
    }

    /// Device-local agent-activity log (plans/cli-mcp.md Phase 2). Lives in
    /// the app's own Application Support directory — NEVER the synced
    /// sidecar root or an iCloud container (a synced audit log would be
    /// LWW-merged across devices and burn the quota the write budget
    /// protects). Owned here, independent of the channel's running state,
    /// so the Recently Deleted screen works while the channel is off.
    let auditLog = MCPAuditLog(fileURL: MCPHostController.auditLogURL())

    init(service: SyncService, repository: ContactsRepository) {
        self.service = service
        self.repository = repository
        super.init()
    }

    private static func auditLogURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("AgentActivity", isDirectory: true)
            .appendingPathComponent("agent-activity.jsonl")
    }

    /// Backing model for the app's Recently Deleted screen: the audit log's
    /// delete entries resolved against the SAME live repository/service
    /// instances the UI uses, restores routed through the same write paths.
    func makeRecentlyDeletedService() -> RecentlyDeletedService {
        RecentlyDeletedService(audit: auditLog, contacts: repository, events: service)
    }

    // MARK: - Lifecycle

    /// Call from `didFinishLaunching`: installs toggle observers and aligns
    /// the channel with the current toggle state.
    func bootstrap() {
        if let defaults = groupDefaults {
            defaults.addObserver(
                self, forKeyPath: MCPToggleKeys.isMCPEnabled,
                options: [.new], context: Self.kvoContext)
            defaults.addObserver(
                self, forKeyPath: MCPToggleKeys.isCLIEnabled,
                options: [.new], context: Self.kvoContext)
            observerInstalled = true
        } else {
            Self.log.error("mcp host: no shared-container defaults; toggles unobservable")
        }
        Task { @MainActor [weak self] in
            await self?.applyDesiredState()
        }
    }

    /// Call from `applicationWillTerminate`. Best-effort: the OS may kill
    /// the process before the teardown Task runs; the kernel reclaims FIFO
    /// FDs either way, and helpers re-handshake on our next launch.
    func shutdown() {
        isShuttingDown = true
        if observerInstalled, let defaults = groupDefaults {
            defaults.removeObserver(self, forKeyPath: MCPToggleKeys.isMCPEnabled, context: Self.kvoContext)
            defaults.removeObserver(self, forKeyPath: MCPToggleKeys.isCLIEnabled, context: Self.kvoContext)
            observerInstalled = false
        }
        Task { @MainActor [weak self] in
            await self?.stop()
        }
    }

    override nonisolated func observeValue(
        forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        guard context == Self.kvoContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        Task { @MainActor [weak self] in
            await self?.applyDesiredState()
        }
    }

    // MARK: - State machine

    private func applyDesiredState() async {
        guard !isShuttingDown else { return }
        let defaults = groupDefaults
        let desired = (defaults?.bool(forKey: MCPToggleKeys.isMCPEnabled) ?? false)
            || (defaults?.bool(forKey: MCPToggleKeys.isCLIEnabled) ?? false)
        switch (desired, state) {
        case (true, .stopped):
            await start()
        case (false, .running):
            await stop()
        default:
            break // in transition (a tail reconcile re-checks) or already there
        }
    }

    private func start() async {
        guard state == .stopped else { return }
        state = .starting

        guard let groupID = CLIHelper.appGroupID,
              let container = WireEnvironment.containerURL(groupID: groupID)
        else {
            Self.log.error("mcp host: shared container unavailable; not starting")
            state = .stopped
            return
        }

        let gates = MCPGates(service: service, defaults: UserDefaults(suiteName: groupID))
        let dispatcher = ToolDispatcher(
            contacts: repository, events: service, guides: service, gates: gates,
            audit: auditLog)
        let newHost = MCPPipeHost(
            container: container,
            handler: { request in await dispatcher.handle(request) },
            logger: nil)
        do {
            try await newHost.startListening()
        } catch {
            Self.log.error("mcp host: failed to start", ["error": "\(error)"])
            state = .stopped
            return
        }
        host = newHost
        state = .running
        Self.log.notice("mcp host: running", ["container": container.path])

        // Reconcile any toggle flip that arrived while starting.
        Task { @MainActor [weak self] in
            await self?.applyDesiredState()
        }
    }

    private func stop() async {
        guard state == .running, let runningHost = host else { return }
        state = .stopping
        await runningHost.stopListening()
        host = nil
        state = .stopped
        Self.log.notice("mcp host: stopped")

        if !isShuttingDown {
            Task { @MainActor [weak self] in
                await self?.applyDesiredState()
            }
        }
    }
}

/// Live gate state for the dispatch core: master toggles from the shared
/// container defaults (read per call, so a Preferences flip applies
/// immediately) + the app's real permission state.
@MainActor
final class MCPGates: MCPGateSource {
    private let service: SyncService
    private let defaults: UserDefaults?

    init(service: SyncService, defaults: UserDefaults?) {
        self.service = service
        self.defaults = defaults
    }

    var isMCPEnabled: Bool { defaults?.bool(forKey: MCPToggleKeys.isMCPEnabled) ?? false }
    var isCLIEnabled: Bool { defaults?.bool(forKey: MCPToggleKeys.isCLIEnabled) ?? false }
    var isMCPReadOnly: Bool { defaults?.bool(forKey: MCPToggleKeys.isMCPReadOnly) ?? true }
    var isCLIReadOnly: Bool { defaults?.bool(forKey: MCPToggleKeys.isCLIReadOnly) ?? true }
    var contactsAuthorized: Bool { service.contactsAuthorization == .authorized }
    var eventsAuthorized: Bool { service.eventsAuthorization == .authorized }
}

/// The dispatch core reaches the app's event/guide reads through these
/// seams; every method already exists on `SyncService` with the exact
/// shape, so the conformances are declarative (INV-2b: live instance,
/// injected).
extension SyncService: MCPEventSource {}
extension SyncService: MCPGuideSource {}

#endif
