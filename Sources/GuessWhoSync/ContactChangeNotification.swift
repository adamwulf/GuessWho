import Foundation

public extension Notification.Name {
    /// Posted by `ContactChangeWatcher` after it reads an external
    /// contact-store delta. Subscribers (the app's repositories) consume the
    /// payload from `userInfo` and refresh themselves; the watcher owns the
    /// observer, cursor, and coalescing.
    ///
    /// Two payload shapes (see the `userInfo` keys below):
    /// - a `ContactChangeSet` of external mutations to apply incrementally, OR
    /// - a "full reload required" flag (first run / history truncation) telling
    ///   the subscriber to drop its cache and re-read everything.
    ///
    /// CRITICAL: an empty delta (e.g. our own writes, excluded via
    /// `transactionAuthor`) is NOT posted — the watcher advances the cursor
    /// silently. So receiving this notification always means there is real work
    /// to do.
    ///
    /// The name and keys are developer/internal-facing; the `guessWho`
    /// vocabulary is intentional and never surfaces in any user-facing string.
    static let guessWhoContactsDidChange = Notification.Name("GuessWhoContactsDidChange")
}

/// `userInfo` keys for `.guessWhoContactsDidChange`. Namespaced constants so
/// there is exactly one place that spells each key, shared by the watcher
/// (poster) and the repositories (subscribers).
public enum GuessWhoContactsDidChangeKey {
    /// Value: a `ContactChangeSet`. Present on an incremental-delta post; the
    /// subscriber applies `changeSet.changes` in order. Absent when the post is
    /// a full-reload signal.
    public static let changeSet = "changeSet"

    /// Value: a `Bool` that is always `true` when present. Present on a
    /// full-reload post (first run / history truncation); the subscriber drops
    /// its cache and re-reads everything. Absent on an incremental-delta post.
    public static let requiresFullReload = "requiresFullReload"
}
