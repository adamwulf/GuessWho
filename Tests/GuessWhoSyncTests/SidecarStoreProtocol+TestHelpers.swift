import Foundation
@testable import GuessWhoSync

// Test convenience: iterate keysWithUnresolvedConflicts then call
// reconcileConflict for each. The orchestrator (production code) drives
// the same loop inline while holding its per-key lock; tests don't need
// the lock and can use this shorthand.
extension SidecarStoreProtocol {
    func reconcileAllConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome] {
        var outcomes: [SidecarReconcileReport.FileOutcome] = []
        for key in try keysWithUnresolvedConflicts() {
            if let outcome = try reconcileConflict(at: key, resolve: { versions in
                try resolve(key, versions)
            }) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }
}
