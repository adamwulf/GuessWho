import Foundation

public enum GroupMemberScopeAvailability: Sendable, Equatable {
    case available, unavailable, deleted
}

/// Loading policy shared by the member list and its race tests. Keeps the last
/// accepted result while refreshing; a stale result is never published, even
/// if changes continue through several consecutive reads.
@MainActor
public final class GroupMemberListLoader {
    public enum Status: Equatable {
        case idle, loading, loaded, unavailable, disappeared
    }

    public private(set) var snapshot: GroupMemberSnapshot?
    public private(set) var status: Status = .idle
    public var onChange: () -> Void = {}

    private let repository: ContactsRepository
    private let scope: GroupMemberScope
    private var generation = UUID()
    private var task: Task<Void, Never>?

    public init(scope: GroupMemberScope, repository: ContactsRepository) {
        self.scope = scope
        self.repository = repository
    }

    deinit { task?.cancel() }

    public func reload() {
        guard status != .disappeared else { return }
        generation = UUID()
        task?.cancel()
        guard scopeIsAvailable() else { return }
        status = .loading
        onChange()
        fetch(generation: generation, staleReads: 0)
    }

    /// Called for hierarchy/contact notifications, including during a load.
    /// An in-flight read checks revisions itself before publication.
    public func repositoryDidChange() {
        guard status != .disappeared, scopeIsAvailable() else { return }
        guard status != .loading else { return }
        if status == .unavailable || snapshot.map({ !repository.isCurrent($0) }) ?? true {
            reload()
        }
    }

    private func scopeIsAvailable() -> Bool {
        let nextStatus: Status
        switch repository.memberScopeAvailability(for: scope) {
        case .available: return true
        case .unavailable: nextStatus = .unavailable
        case .deleted: nextStatus = .disappeared
        }
        generation = UUID()
        task?.cancel()
        if status != nextStatus {
            status = nextStatus
            onChange()
        }
        return false
    }

    private func fetch(generation request: UUID, staleReads: Int) {
        // Neither the fetch nor the delayed retry retains the loader/view.
        // Dropping the view cancels retries even if the store never settles.
        task = Task { [weak self, repository, scope] in
            if staleReads >= 3 {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let result = await repository.memberSnapshot(for: scope)
            guard !Task.isCancelled, let self, self.generation == request else { return }
            // This check also runs after the INITIAL load: deletion during its
            // await must navigate away, while unavailable data preserves rows.
            guard self.scopeIsAvailable() else { return }
            guard repository.isCurrent(result) else {
                self.fetch(generation: request, staleReads: staleReads + 1)
                return
            }
            self.snapshot = result
            self.status = .loaded
            self.task = nil
            self.onChange()
        }
    }
}
