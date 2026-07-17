import Foundation
import Logging
import Observation

public extension Notification.Name {
    /// Posted after a `ContactsRepository` cache mutation completes.
    /// Consumers that do not use Observation (for example UIKit diffable data
    /// sources) can observe this notification and apply one new snapshot.
    static let contactsRepositoryDidReload = Notification.Name("ContactsRepositoryDidReload")
}

/// userInfo keys for `.contactsRepositoryDidReload`.
public enum ContactsRepositoryDidReloadKey {
    /// `Bool` — `true` when contact RECORDS (fields, photo bytes, membership
    /// of the cache) may have changed; `false` for presentation-only posts
    /// where every cached record is unchanged and only ordering/derived state
    /// moved (a sort-order flip, a timestamp stamp, a groups refresh).
    /// Consumers holding caches KEYED ON CONTACT DATA (e.g. decoded photos)
    /// may skip invalidation when this is `false`; snapshot-applying list
    /// consumers should re-render regardless. Absent means `true`.
    public static let contactDataChanged = "contactDataChanged"
}

/// Package-owned in-memory read repository for Contacts.
///
/// Deliberately a read-model cache, not a second source of truth: Contacts
/// remains authoritative. It owns the full reload and incremental-change
/// mechanics so all UI clients observe one coherent view of the address book,
/// and preserves the app's established list-query behavior as a transitional
/// compatibility API.
@MainActor
@Observable
public final class ContactsRepository: NSObject {
    private let contactsStore: ContactStoreProtocol

    // The sidecar write engine and the standalone favorites store. BOTH are
    // Optional and nil in the `.unavailable` storage state (no writable sidecar
    // root). Both are reference-type classes; holding them on this
    // `@MainActor`-isolated repository keeps access race-free (`GuessWhoSync` is
    // `@unchecked Sendable`, so the stored reference crosses no isolation
    // boundary). Methods that depend on either MUST degrade when nil: reads
    // return empty/false, writes throw `SidecarUnavailableError`.
    private let sync: GuessWhoSync?
    private let favorites: FavoritesStore?

    /// The center this repository observes `.guessWhoContactsDidChange` on AND
    /// the one a write-side refresh would notify. Defaults to `.default` so
    /// production wiring is unchanged: the live `ContactChangeWatcher` posts on
    /// `.default`, so a real external contact change still refreshes this repo.
    ///
    /// It is INJECTABLE solely for test isolation. The watcher posts with
    /// `object: self`, but the repository holds no reference to its watcher, so
    /// it must observe with `object: nil` to hear the process-wide "contacts
    /// changed" signal. In production that is harmless — there is exactly one
    /// repository. In tests, many repositories share `.default`, so one test's
    /// post would fire EVERY live repo's `contactsDidChange` — a parallel test's
    /// repo would apply a change set for localIDs it never owned and corrupt its
    /// assertions. A fresh `NotificationCenter()` per test repository confines
    /// its observer to that center: production refresh stays on `.default`, and
    /// parallel `swift test` becomes deterministic (without it, parallel runs
    /// flake while `--no-parallel` passes).
    private let notificationCenter: NotificationCenter

    public private(set) var contacts: [Contact] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public var peopleSearch = ""
    public var organizationsSearch = ""

    /// People and Organizations keep independent relationship filters while
    /// sharing the same contact cache and global sort order. Changing either
    /// filter is presentation-only and immediately republishes the derived
    /// sections; search and sort remain in effect.
    public var peopleFilter: LinkFilter = .all {
        didSet {
            guard peopleFilter != oldValue else { return }
            postDidReload(contactDataChanged: false)
        }
    }
    public var organizationsFilter: LinkFilter = .all {
        didSet {
            guard organizationsFilter != oldValue else { return }
            postDidReload(contactDataChanged: false)
        }
    }

    /// Contacts.app groups (`CNGroup`), cached for the Groups list. Filled by
    /// `loadGroups()`; a failed fetch leaves an empty array and records
    /// `lastError`, exactly like `reload()` does for contacts. Groups are
    /// read-only here — the sidecar does not mirror them and there is no
    /// membership-mutation path through this repository surface.
    public private(set) var groups: [ContactGroup] = []

    // MARK: - Point-lookup indexes (private; rebuilt from `contacts`)
    //
    // These make `contact(id:)`, `contact(guessWhoID:)`, `contact(localID:)`,
    // and `contactIDs(matchingEmail:)` O(1) synchronous main-actor reads. They
    // are NEVER mutated directly — every `contacts` assignment routes through
    // `setContacts(_:)`, which reassigns the array AND rebuilds all three
    // indexes wholesale, so they cannot drift. The wholesale rebuild also makes
    // the reconciliation transition — a contact gaining a `guessWhoID` — re-key
    // automatically: the new array yields a fresh `guessWhoIDToLocalID` pointer
    // (dropping any stale one) while the `localID` slot is unchanged.

    /// Keyed on `localID` (Apple's `CNContact.identifier`), one entry per
    /// contact. Backs the `contact(localID:)` Contacts-boundary accessor AND is
    /// the SOLE `Contact` cache — every other identity lookup chases a pointer
    /// into this map, so there is exactly one `Contact` value per contact and
    /// copies cannot drift.
    private var contactsByLocalID: [String: Contact] = [:]

    /// Pointer index: canonical (lowercase) `guessWhoID` → that contact's
    /// `localID`. Holds ONLY RECONCILED contacts (those whose
    /// `ContactID(contact:).guessWhoID != nil`); it stores no `Contact` value,
    /// just the `localID` to chase back into `contactsByLocalID`. Backs the
    /// guessWhoID branch of `contact(id:)` and all of `contact(guessWhoID:)`.
    /// Keys are canonical-lowercase off `ContactID`.
    private var guessWhoIDToLocalID: [String: String] = [:]

    /// Keyed on each lowercased+trimmed email address a contact carries; a
    /// contact appears under EVERY email it has, and one email can map to
    /// MULTIPLE contacts (duplicates are preserved). Backs
    /// `contactIDs(matchingEmail:)`.
    private var contactsByEmail: [String: [Contact]] = [:]

    /// Bulk cache of every contact's sidecar timestamps, keyed on the lowercased
    /// GuessWho UUID (matching `GuessWhoSync.allContactTimestamps()` and
    /// `ContactID.guessWhoID`). Refreshed wholesale in `reload()` and after each
    /// stamp write; a failed read leaves it empty. Backs the three time-ordered
    /// sorts and their relative-time bucketing; an unreconciled contact (no
    /// GuessWho UUID) has no entry and sorts/buckets as "no timestamp" (oldest /
    /// "Earlier"). Purely derived read-model state, so NOT `@Observable`-tracked
    /// — list re-renders come from the `contacts`/`sortOrder` changes and
    /// `postDidReload()`.
    @ObservationIgnored private var contactTimestampsByID: [String: ContactTimestamps] = [:]

    /// Canonical GuessWho UUIDs for contact endpoints participating in at
    /// least one live link. Refreshed in the same sidecar-derived passes as
    /// timestamps so Linked filters react to both local and iCloud changes.
    @ObservationIgnored private var linkedContactIDs: Set<String> = []

    /// Per-contact link COUNT keyed by canonical GuessWho UUID string. Powers
    /// the "N links" list badge; refreshed in the same sidecar-derived passes
    /// as `linkedContactIDs`. A contact with no entry has zero links and shows
    /// no badge. Purely derived read-model state, so `@ObservationIgnored` like
    /// its sibling overlays.
    @ObservationIgnored private var linkCountsByID: [String: Int] = [:]

    /// The CURRENT global list sort order. The repository holds it; the APP owns
    /// persistence (e.g. `UserDefaults`, via the stable `rawValue`s) and sets it
    /// here. Setting it re-renders every list: it is `@Observable`-tracked AND
    /// posts `.contactsRepositoryDidReload` (via `didSet`) so both Observation
    /// and notification-based consumers (the UIKit diffable lists) refresh.
    public var sortOrder: ContactSortOrder = .lastFirst {
        didSet {
            guard sortOrder != oldValue else { return }
            // Ordering changed; every cached record is untouched.
            postDidReload(contactDataChanged: false)
        }
    }

    /// - Parameter notificationCenter: the center to observe
    ///   `.guessWhoContactsDidChange` on. Defaults to `.default` (production
    ///   wiring); tests pass a fresh `NotificationCenter()` per instance so a
    ///   post from one repository's test cannot fire another's observer. See the
    ///   `notificationCenter` property doc for the full root cause.
    public init(
        contacts: ContactStoreProtocol,
        sync: GuessWhoSync? = nil,
        favorites: FavoritesStore? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.contactsStore = contacts
        self.sync = sync
        self.favorites = favorites
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.addObserver(
            self,
            selector: #selector(contactsDidChange(_:)),
            name: .guessWhoContactsDidChange,
            object: nil
        )
        // Sidecar files changed on disk (an iCloud arrival from another
        // device, a `notYetDownloaded` file materializing, or a same-device
        // write echo). Contacts.app records are untouched by definition, so
        // the handler refreshes only the sidecar-derived projection — see
        // `refreshFromSidecarChange()`.
        notificationCenter.addObserver(
            self,
            selector: #selector(sidecarsDidChange(_:)),
            name: .guessWhoSidecarsDidChange,
            object: nil
        )
    }

    /// Rebuild the cache from Contacts. A failed fetch leaves an empty cache
    /// and records the error; this preserves the existing app behavior for a
    /// denied permission or a transient Contacts failure.
    public func reload() async {
        isLoading = true
        do {
            setContacts(try await contactsStore.fetchAll())
            lastError = nil
        } catch {
            setContacts([])
            lastError = "Contacts fetch failed: \(error.localizedDescription)"
        }
        await refreshTimestampCache()
        await refreshLinkedContactIDs()
        await refreshLinkCounts()
        // NotificationCenter can deliver synchronously. Consumers must observe
        // the settled loading state when they apply their post-reload snapshot.
        isLoading = false
        postDidReload()
    }

    /// Reload the bulk timestamp cache from the engine, wholesale. ROBUST: a
    /// nil engine or a failed read leaves the cache EMPTY (every contact then
    /// sorts/buckets as "no timestamp") rather than throwing. Called only from
    /// a full `reload()`; the stamp path upserts its one entry in place
    /// (`updateTimestampCache`) instead.
    ///
    /// The scan reads every contact sidecar (a coordinated read + decode per
    /// file), so it hops off the caller's actor via the engine's async
    /// `allContactTimestamps()` overload (a `DispatchQueue.global` continuation
    /// hop, not the cooperative pool). A stamp that lands DURING the scan can be
    /// briefly shadowed by the wholesale replace below (its cell is on disk, so
    /// the next reload sees it) — a stale-by-one-frame sort, never data loss.
    private func refreshTimestampCache() async {
        guard let sync else {
            contactTimestampsByID = [:]
            return
        }
        contactTimestampsByID = (try? await sync.allContactTimestamps()) ?? [:]
    }

    private func refreshLinkedContactIDs() async {
        guard let sync else {
            linkedContactIDs = []
            return
        }
        let endpoints = (try? await sync.linkedEndpoints(ofKind: .contact)) ?? []
        linkedContactIDs = Set(endpoints.map(\.id))
    }

    private func refreshLinkCounts() async {
        guard let sync else {
            linkCountsByID = [:]
            return
        }
        let counts = (try? await sync.linkCounts(ofKind: .contact)) ?? [:]
        linkCountsByID = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.id, $0.value) })
    }

    // MARK: - Groups (read-only)
    //
    // Groups are Contacts.app groups (`CNGroup`), read directly from the store —
    // the sidecar does not mirror them. The Groups UI is read-only, so the
    // repository exposes only a list fetch and a members fetch; the store's
    // membership-mutation methods are intentionally not surfaced here.

    /// Rebuild the `groups` cache from Contacts, sorted by name. A failed fetch
    /// leaves an empty cache and records `lastError`, mirroring `reload()`'s
    /// degrade-gracefully behavior. Posts `.contactsRepositoryDidReload` so the
    /// Groups list controller refreshes through the same notification path the
    /// People/Organizations lists use.
    public func loadGroups() async {
        do {
            let fetched = try await contactsStore.fetchAllGroups()
            groups = fetched.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            lastError = nil
        } catch {
            groups = []
            lastError = "Groups fetch failed: \(error.localizedDescription)"
        }
        // Groups moved; the CONTACT records in the cache are untouched.
        postDidReload(contactDataChanged: false)
    }

    /// The members of the group identified by `groupLocalID`, as `Contact`s.
    /// Returns the contacts straight from the store so the caller can section
    /// them A–Z with the same `Contact`-level helpers the People/Organizations
    /// lists use. A failed fetch returns an empty array and records `lastError`,
    /// matching the degrade-gracefully behavior of `reload()` / `loadGroups()`.
    /// `groupLocalID` is the Contacts `CNGroup.identifier` (`ContactGroup.localID`),
    /// the correct key for membership — groups are not GuessWho-ID'd.
    public func members(ofGroup groupLocalID: String) async -> [Contact] {
        do {
            // A pure read must NOT clear `lastError` on success — `lastError` is
            // a shared slot that a concurrent contacts reload may have set, and
            // clearing it here could mask a genuine reload failure. Only the
            // failure path below writes it.
            return try await contactsStore.fetchMembers(ofGroup: groupLocalID)
        } catch {
            lastError = "Group members fetch failed: \(error.localizedDescription)"
            return []
        }
    }

    /// The Contacts.app groups that `contact` belongs to, sorted by name.
    /// Membership is keyed by Contacts `localID` (`CNContact.identifier`) — the
    /// correct key, since groups are not GuessWho-ID'd — which this method reads
    /// off the value so the app never has to touch the confined `localID`. A
    /// failed fetch returns an empty array and records `lastError`, matching the
    /// degrade-gracefully behavior of `members(ofGroup:)`. Like that pure read,
    /// success does NOT clear `lastError` — a concurrent reload may have set it.
    public func groups(containing contact: Contact) async -> [ContactGroup] {
        do {
            let memberships = try await contactsStore.fetchGroupMemberships(
                contactLocalID: contact.localID
            )
            return memberships.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            lastError = "Group memberships fetch failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Returns a currently-cached contact for an adapter-local refresh token.
    /// `localID` is intentionally confined to this Contacts-boundary API; it
    /// must not be persisted or used as application identity.
    package func contact(localID: String) -> Contact? {
        contactsByLocalID[localID]
    }

    // MARK: - ContactID-addressed reads
    //
    // All accessors below are synchronous main-actor reads over the in-memory
    // `contacts` cache. NONE of them enumerate `CNContactStore` — the cache is
    // the read model and Contacts is refreshed only via `reload()` /
    // `refreshContact(localID:)`. The UI keys exclusively on `ContactID`; the
    // `localID` carrier inside the value is consumed only by `contact(id:)`.

    /// Resolves a `ContactID` back to its cached `Contact`, GuessWho UUID FIRST
    /// (canonical identity wins; a stale `localID` can never override a real UUID
    /// match), else by `localID`. Returns `nil` when no cached contact matches
    /// (deleted, or a retired/unknown id) — the "unavailable" contract the UI
    /// renders, never a wrong-contact fallback.
    ///
    /// The `localID` branch is LOAD-BEARING: it is the captured-pre-reconcile-
    /// token case — a view holds an immutable `ContactID` minted at navigation
    /// whose `guessWhoID` is still nil, and the contact then reconciled.
    /// `localID` is the one identifier that does NOT move across the reconcile
    /// re-key, so resolution MUST go by `id.localID` there. Do NOT "simplify"
    /// this branch away.
    ///
    /// It is safe even for a retired/Case-D-loser UUID: Apple never reuses a
    /// deleted `CNContact.identifier`, so a token whose `guessWhoID` left the
    /// book falls through to a `localID` slot that is now empty → nil, never a
    /// wrong contact. (A reconciled token whose UUID is still present hits the
    /// pointer index and never reaches this branch.)
    public func contact(id: ContactID) -> Contact? {
        if let gw = id.guessWhoID, let lid = guessWhoIDToLocalID[gw] {
            return contactsByLocalID[lid]
        }
        return contactsByLocalID[id.localID]
    }

    /// Resolve a persisted `ContactRestorationToken` (from UI state restoration)
    /// back to the current `Contact`, or nil if it can no longer be safely found.
    ///
    /// Resolves the opaque `ContactID` the token snapshotted through
    /// `contact(id:)` (`guessWhoID`-first, `localID` fallback), so a reconciled
    /// contact reopens by its canonical identity and a viewed-but-never-written
    /// contact reopens by its device-local `localID`.
    ///
    /// It adds ONE guard that raw `contact(id:)` does not, specific to
    /// restoration: if the token carried a `guessWhoID` but resolution had to
    /// fall through to the `localID` slot (the `guessWhoID` is retired/unknown —
    /// a Case-D loser or a deleted record), the found contact is only accepted if
    /// it STILL carries that same `guessWhoID`. Otherwise Contacts unification may
    /// have re-pointed that `localID` at a DIFFERENT person, and reopening a
    /// stranger's card is worse than reopening nothing — so we return nil and the
    /// caller restores the section only. A token with no `guessWhoID` (an
    /// unwritten contact) has nothing to verify and uses the plain `localID`
    /// resolution.
    public func contact(restorationToken: ContactRestorationToken) -> Contact? {
        guard let resolved = contact(id: restorationToken.contactID) else { return nil }
        // Only the retired-guessWhoID + localID-fallback case needs the extra
        // check. If the token had no guessWhoID, or the resolved contact matches
        // it, `contact(id:)`'s result stands.
        guard let tokenGuessWhoID = restorationToken.guessWhoID else { return resolved }
        let resolvedGuessWhoID = SidecarKey.forContact(resolved)?.id
        return resolvedGuessWhoID == tokenGuessWhoID ? resolved : nil
    }

    /// Developer breadcrumbs for the photo read path (which branch produced a
    /// nil, flag/bytes disagreements, thrown store errors). File-log only —
    /// never user-facing.
    private static let photoLog = Logger(label: "sync.contact-photo")

    /// Same label as the adapter's save-failure breadcrumbs so one grep shows
    /// every CNContact write REQUEST alongside any failure — a 2026-07-03
    /// mystery save failure was unattributable because nothing recorded which
    /// operation initiated it.
    private static let saveLog = Logger(label: "sync.contact-save")

    /// Lazily loads contact photo bytes for the app-facing `ContactID`.
    ///
    /// Bulk contact reloads only fetch `imageDataAvailable`; the expensive image
    /// bytes stay behind this visible-row/detail-driven path. The app passes an
    /// opaque `ContactID`; the repository resolves the package-scoped Contacts
    /// lookup token internally and chooses thumbnail vs. full-size store access.
    ///
    /// `imageDataAvailable` is a HINT, never a veto: macOS/Catalyst can leave a
    /// card thumbnail-only with the flag stuck `false` (observed 2026-07-03
    /// after a LinkedIn photo import — Contacts.app rendered the thumbnail
    /// while the flag read `false` and full-size `imageData` was nil), so this
    /// always asks the store. A `.fullSize` request on such a card falls back
    /// to the thumbnail bytes — the returned `ContactPhoto.kind` reports what
    /// the bytes actually are. The app-side loader caches empty results, so
    /// photo-less books don't re-query the store on every scroll.
    public func contactPhotoData(for id: ContactID, kind: ContactPhotoKind) async throws -> ContactPhoto? {
        guard let contact = contact(id: id) else { return nil }

        do {
            switch kind {
            case .thumbnail:
                guard let data = try await contactsStore.loadThumbnailImageData(localID: contact.localID) else {
                    if contact.imageDataAvailable {
                        Self.photoLog.notice("thumbnail missing despite imageDataAvailable=true", metadata: [
                            "localID": .string(contact.localID),
                        ])
                    }
                    return nil
                }
                Self.logFlagMismatchIfNeeded(contact: contact, loaded: "thumbnail", bytes: data.count)
                return ContactPhoto(data: data, kind: .thumbnail)
            case .fullSize:
                if let data = try await contactsStore.loadImageData(localID: contact.localID) {
                    Self.logFlagMismatchIfNeeded(contact: contact, loaded: "fullSize", bytes: data.count)
                    return ContactPhoto(data: data, kind: .fullSize)
                }
                // Thumbnail-only card: full-size bytes unavailable at the API
                // even though a photo exists. Contacts.app shows the thumbnail
                // in that state, so we do too.
                guard let thumbnail = try await contactsStore.loadThumbnailImageData(localID: contact.localID) else {
                    if contact.imageDataAvailable {
                        Self.photoLog.notice("no photo bytes despite imageDataAvailable=true", metadata: [
                            "localID": .string(contact.localID),
                        ])
                    }
                    return nil
                }
                Self.photoLog.notice("full-size photo unavailable; serving thumbnail", metadata: [
                    "localID": .string(contact.localID),
                    "imageDataAvailable": .stringConvertible(contact.imageDataAvailable),
                    "thumbnailBytes": .stringConvertible(thumbnail.count),
                ])
                return ContactPhoto(data: thumbnail, kind: .thumbnail)
            }
        } catch ContactStoreError.contactNotFound(_) {
            return nil
        } catch {
            let ns = error as NSError
            Self.photoLog.error("contact photo load failed", metadata: [
                "localID": .string(contact.localID),
                "kind": .string(kind == .thumbnail ? "thumbnail" : "fullSize"),
                "domain": .string(ns.domain),
                "code": .stringConvertible(ns.code),
                "localizedDescription": .string(ns.localizedDescription),
            ])
            throw error
        }
    }

    /// One breadcrumb when bytes load fine but the record's availability flag
    /// said there were none — the flag-stuck-false state that used to blank
    /// every photo surface.
    private static func logFlagMismatchIfNeeded(contact: Contact, loaded: String, bytes: Int) {
        guard !contact.imageDataAvailable else { return }
        photoLog.notice("photo loaded despite imageDataAvailable=false", metadata: [
            "localID": .string(contact.localID),
            "loaded": .string(loaded),
            "bytes": .stringConvertible(bytes),
        ])
    }

    /// Fetches the current Contacts record for editing, addressed by the
    /// app-facing `ContactID`. The package resolves the adapter-local Contacts
    /// identifier at the boundary and then uses the fresh `fetch(localID:)`
    /// path, which is more reliable than the bulk cache immediately after
    /// Contacts writes on Catalyst.
    public func editableContact(id: ContactID) async throws -> Contact? {
        guard let localID = contact(id: id)?.localID else { return nil }
        return try await contactsStore.fetch(localID: localID)
    }

    /// Saves an edited Contacts record and refreshes that exact record in the
    /// repository cache. The edited value carries the local Contacts identifier
    /// from `editableContact(id:)`; keeping that read inside the package avoids
    /// re-resolving a possibly stale navigation token after a reconcile.
    public func saveContact(_ edited: Contact, for _: ContactID) async throws {
        Self.saveLog.notice("contact save requested", metadata: [
            "op": "saveContact", "localID": .string(edited.localID),
        ])
        try await contactsStore.save(edited)
        await refreshContact(localID: edited.localID)
    }

    /// Creates a brand-new Contacts record from `seed` (its `localID` is
    /// ignored — the store issues one) and pulls it into the repository cache.
    /// Returns the cached contact, whose `contactID` addresses the new record
    /// for follow-up work: opening the detail view, applying LinkedIn extras.
    /// The single package entry point behind both the app's "+" (blank seed)
    /// and the LinkedIn no-match import (profile-filled seed). No reconcile —
    /// creating a card is a CONTACT write, not a sidecar write; the GuessWho
    /// ID mints on the first sidecar write as usual.
    public func createContact(_ seed: Contact) async throws -> Contact {
        Self.saveLog.notice("contact save requested", metadata: ["op": "createContact"])
        let created = try await contactsStore.create(seed)
        await refreshContact(localID: created.localID)
        return contact(localID: created.localID) ?? created
    }

    /// Sets (or clears, with `nil`) the contact's photo bytes on its Contacts
    /// record, addressed by the app-facing `ContactID`. Image bytes go through
    /// the store's dedicated photo-write path (not `save`), then the one record
    /// is re-read so its `imageDataAvailable` flag reflects the write. The app
    /// is responsible for invalidating any cached decoded image afterwards.
    /// Returns `false` when the id no longer resolves to a contact.
    ///
    /// PREVIOUS-PHOTO SNAPSHOT: before overwriting an EXISTING photo, the current
    /// bytes are captured into a single-slot "previous photo" so a replacement is
    /// recoverable — a general rule on the contact-image write path, so every
    /// caller that replaces a photo gets it for free. Best-effort: it never
    /// blocks the actual photo write; a failure is recorded in `lastError` only.
    @discardableResult
    public func setContactPhoto(for id: ContactID, imageData: Data?) async throws -> Bool {
        guard let localID = contact(id: id)?.localID else { return false }
        await snapshotCurrentPhotoIfPresent(for: id, localID: localID)
        Self.saveLog.notice("contact save requested", metadata: [
            "op": "setContactPhoto", "localID": .string(localID),
            "bytes": .stringConvertible(imageData?.count ?? 0),
        ])
        try await contactsStore.setImageData(localID: localID, imageData: imageData)
        await refreshContact(localID: localID)
        return true
    }

    /// Read-before-write: if the contact currently HAS a photo, snapshot those
    /// bytes into a single-slot `previousPhoto` `.blob` before the caller
    /// overwrites them. No current photo → snapshot nothing. The snapshot is a
    /// sidecar write, so a nil engine silently skips it — the photo write still
    /// proceeds.
    ///
    /// Resolving the GuessWho UUID can MINT one for a previously-unreconciled
    /// contact (the same resolve-or-mint path the other sidecar writes use), so
    /// the cache is refreshed if that happens.
    private func snapshotCurrentPhotoIfPresent(for id: ContactID, localID: String) async {
        guard let sync else { return }
        do {
            // Read the CURRENT full-size bytes that are about to be replaced.
            guard let currentBytes = try await contactsStore.loadImageData(localID: localID),
                  !currentBytes.isEmpty else { return }

            let minted = id.guessWhoID == nil
            let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
            let key = SidecarKey(kind: .contact, id: guessWhoID)
            // Single-slot upsert: repoints the slot and reclaims the prior
            // `.dat` (orphan sweep is the cross-device backstop). Awaits the
            // engine's background-hop overload — encrypting and writing a
            // full-size photo must not stall the main actor mid-import.
            _ = try await sync.setBlobField(
                at: key,
                field: Self.previousPhotoFieldName,
                data: currentBytes,
                contentType: Self.imageContentType(of: currentBytes)
            )
            await refreshCacheIfMinted(minted, localID: localID)
        } catch {
            // Best-effort: the snapshot must never block the photo write.
            lastError = "previous-photo snapshot failed: \(error.localizedDescription)"
        }
    }

    /// The single-slot field name the previous-photo snapshot lives under. An
    /// INTERNAL identifier, NOT a display string: `fields(for:)` excludes its
    /// `.blob` field from the user-visible custom-fields list, so the raw
    /// "previousPhoto" token never reaches the UI. A future "previous photo"
    /// feature would render its own plain-language label and read the bytes via
    /// `GuessWhoSync.blobFieldData`, not surface this name. v1 only guarantees
    /// capture.
    static let previousPhotoFieldName = "previousPhoto"

    /// Field NAMES that external writers (the CLI/MCP write tools, imports)
    /// must never create or replace via the upsert-by-name path. The upsert
    /// REPLACES an existing same-name field of a different type, so a caller
    /// writing a field named "previousPhoto" would clobber the photo-restore
    /// snapshot, and one named "note" would overwrite a user note in place
    /// (`notes(at:)` selects on `field == "note"`). Centralized here, next to
    /// `previousPhotoFieldName`, so a new internal name gets added in one
    /// place (plans/cli-mcp.md Phase 2 custom-field guardrails).
    public nonisolated static let reservedFieldNames: Set<String> = [
        ContactsRepository.previousPhotoFieldName,
        GuessWhoSync.contactNoteFieldName,
        GuessWhoSync.eventTagFieldName,
    ]

    /// Whether `name` collides with a reserved internal field name. The
    /// comparison is case-insensitive on the trimmed name: only the exact
    /// name collides mechanically, but a near-miss ("PreviousPhoto") would
    /// only ever confuse — reject it too.
    public nonisolated static func isReservedFieldName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return reservedFieldNames.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// Best-effort MIME sniff for the snapshot pointer's `contentType`. CN
    /// usually hands back JPEG, sometimes PNG; anything else is recorded as a
    /// generic octet-stream (the bytes are stored faithfully regardless).
    static func imageContentType(of data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        return "application/octet-stream"
    }

    /// Apply selected fields from a parsed LinkedIn profile to an existing
    /// contact and return the refreshed contact. The single package-side entry
    /// point that owns the merge + save rules (the app only chooses which
    /// `fields` to apply and presents the result).
    ///
    /// Rules:
    /// - CNContact fields (name/jobTitle/organization/emails/websites/LinkedIn
    ///   URL) are MERGED, never replaced. New emails/websites are appended to the
    ///   existing set (case-insensitive for emails; scheme-insensitive for URLs);
    ///   existing values — including the internal `guesswho://` identity URL —
    ///   are preserved. Name/title/org overwrite only when that field is chosen.
    /// - Sidecar fields (headline/about/location) are stored as notes prefixed
    ///   with "LinkedIn …: " so the source is obvious to the user.
    /// - `photo` routes through `setContactPhoto`, so replacing an existing
    ///   photo snapshots the replaced bytes into the single-slot previous-photo
    ///   sidecar blob first. Skipped entirely — no write, no snapshot — when
    ///   the incoming bytes equal the contact's current photo (re-import) or
    ///   the payload's data URL doesn't decode.
    ///
    /// Throws if the contact can't be fetched/saved. Returns the refreshed
    /// `Contact` (CNContact fields; sidecar notes are read separately).
    ///
    /// NOTE: adding the headline/about/location notes can MINT a GuessWho ID
    /// for a previously-unreconciled contact. After this call, use the RETURNED
    /// contact's `contactID` for follow-up sidecar reads — an older `ContactID`
    /// held by the caller may be pre-mint (stale).
    @discardableResult
    public func applyLinkedIn(
        profile: LinkedInProfile,
        to id: ContactID,
        fields: Set<LinkedInField>
    ) async throws -> Contact {
        guard var edited = try await editableContact(id: id) else {
            throw ContactStoreError.contactNotFound(localID: id.localID)
        }

        if fields.contains(.name), let full = profile.fullName?.trimmed, !full.isEmpty {
            let parts = full.split(separator: " ", maxSplits: 1).map(String.init)
            edited.givenName = parts.first ?? full
            edited.familyName = parts.count > 1 ? parts[1] : ""
        }
        if fields.contains(.jobTitle), let v = profile.title?.trimmed, !v.isEmpty {
            edited.jobTitle = v
        }
        if fields.contains(.organization), let v = profile.org?.trimmed, !v.isEmpty {
            edited.organizationName = v
        }
        if fields.contains(.emails) {
            let additions = Self.newValues(
                profile.contactInfo?.emails ?? [],
                notIn: edited.emailAddresses.map(\.value),
                key: { $0.trimmed.lowercased() }
            )
            // CNContact field — default label (empty -> the adapter passes nil,
            // so Contacts assigns its own default). NOT "LinkedIn".
            edited.emailAddresses += additions.map { LabeledValue(label: "", value: $0) }
        }
        if fields.contains(.phones) {
            let additions = Self.newValues(
                profile.contactInfo?.phones ?? [],
                notIn: edited.phoneNumbers.map(\.value),
                key: Self.phoneDedupKey
            )
            edited.phoneNumbers += additions.map { LabeledValue(label: "", value: $0) }
        }
        if fields.contains(.websites) {
            let additions = Self.newValues(
                profile.contactInfo?.websites ?? [],
                notIn: edited.urlAddresses.map(\.value),
                key: Self.urlDedupKey
            )
            // CNContact field — default label (empty -> adapter passes nil).
            edited.urlAddresses += additions.map { LabeledValue(label: "", value: $0) }
            if profile.isRiceProfile,
               let riceURL = profile.sourceUrl?.trimmed, !riceURL.isEmpty,
               !edited.urlAddresses.contains(where: { Self.urlDedupKey($0.value) == Self.urlDedupKey(riceURL) }) {
                edited.urlAddresses.append(LabeledValue(label: "Rice", value: riceURL))
            }
        }
        if fields.contains(.linkedInURL),
           let url = (profile.contactInfo?.profileUrl ?? profile.sourceUrl)?.trimmed, !url.isEmpty {
            let slug = LinkedInURL.slug(from: url) ?? ""
            // A LinkedIn social profile is identified by its service ("LinkedIn");
            // existing ones may store only a username (no urlString), so match on
            // service or a same-slug urlString/username, not urlString alone.
            let existingIndex = edited.socialProfiles.firstIndex { lp in
                let p = lp.value
                if p.service.caseInsensitiveCompare("LinkedIn") == .orderedSame { return true }
                if !p.urlString.isEmpty, LinkedInURL.sameProfile(p.urlString, url) { return true }
                if !p.username.isEmpty, !slug.isEmpty, p.username.caseInsensitiveCompare(slug) == .orderedSame { return true }
                return false
            }
            // Contacts' LinkedIn social-profile field expects the USERNAME, not a
            // URL — it derives the URL from the username, and a stored URL shows
            // blank in the normal card view. So store just the slug.
            if let i = existingIndex {
                // Already has a LinkedIn profile — don't duplicate. Fill in the
                // username if it's missing.
                if edited.socialProfiles[i].value.username.isEmpty, !slug.isEmpty {
                    edited.socialProfiles[i].value.username = slug
                }
            } else if !slug.isEmpty {
                edited.socialProfiles.append(LabeledSocialProfile(
                    label: "LinkedIn",
                    value: SocialProfile(urlString: "", username: slug, service: "LinkedIn")
                ))
            }
        }

        try await saveContact(edited, for: id)

        // Sidecar key/value fields (headline/about/location aren't CNContact
        // fields). UPSERT by name (not append-only notes) so re-importing the
        // same profile updates the value instead of duplicating it. Names are
        // prefixed "LinkedIn " so the source is obvious.
        if fields.contains(.headline), let head = profile.headline?.trimmed, !head.isEmpty {
            // The raw headline is a single free-text line (e.g. "Principal AI
            // Consultant | Driving Sustainable Value…"). When the parser had no
            // Experience-derived current position AND the headline didn't parse
            // as "<Title> at <Org>", this field is the only place the title/bio
            // survives.
            _ = try await upsertField(for: id, field: "LinkedIn Headline", value: head, type: .note)
        }
        if fields.contains(.about), let about = profile.about?.trimmed, !about.isEmpty {
            // About is multi-line prose.
            let fieldName = profile.isRiceProfile ? "Rice Bio" : "LinkedIn About"
            _ = try await upsertField(for: id, field: fieldName, value: about, type: .multilineNote)
        }
        if fields.contains(.location), let loc = profile.location?.trimmed, !loc.isEmpty {
            // Location is a single line.
            _ = try await upsertField(for: id, field: "LinkedIn Location", value: loc, type: .note)
        }
        if fields.contains(.department), let department = profile.department?.trimmed, !department.isEmpty {
            // A person can belong to several Rice units; the parser preserves
            // those units one per line, so keep the custom field multiline too.
            _ = try await upsertField(for: id, field: "Rice Department", value: department, type: .multilineNote)
        }

        // Photo: route through the contact-image write path so replacing an
        // existing photo snapshots the replaced bytes into the previous-photo
        // slot for free. Compare against the CURRENT bytes first — a re-import
        // of the same profile must be a no-op, not a snapshot that repoints
        // the previous-photo slot at a copy of the live photo.
        if fields.contains(.photo),
           let incoming = profile.photo?.decodedData(), !incoming.isEmpty {
            let current = try await contactsStore.loadImageData(localID: edited.localID)
            if current != incoming {
                try await setContactPhoto(for: id, imageData: incoming)
            }
        }

        return contact(id: id) ?? edited
    }

    /// New members of `incoming` not already present in `existing`, compared by
    /// `key`, preserving incoming order, de-duped, trimmed, and dropping empties.
    private static func newValues(
        _ incoming: [String],
        notIn existing: [String],
        key: (String) -> String
    ) -> [String] {
        let have = Set(existing.map(key))
        var seen = Set<String>()
        var out: [String] = []
        for raw in incoming {
            let value = raw.trimmed
            let k = key(value)
            guard !k.isEmpty, !have.contains(k), !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(value)
        }
        return out
    }

    /// Scheme-insensitive URL dedup key: strips scheme, a leading `www.`, and a
    /// trailing slash; lowercased. So "adamwulf.me" == "https://www.adamwulf.me/".
    private static func urlDedupKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if t.hasPrefix("www.") { t = String(t.dropFirst(4)) }
        while t.hasSuffix("/") { t = String(t.dropLast()) }
        return t
    }

    private static func phoneDedupKey(_ s: String) -> String {
        s.filter(\.isNumber)
    }

    /// Deletes the cached contact addressed by `ContactID`. Returns `false`
    /// when the id no longer resolves, matching the former app-side guard.
    @discardableResult
    public func deleteContact(id: ContactID) async throws -> Bool {
        guard let localID = contact(id: id)?.localID else { return false }
        try await contactsStore.delete(localID: localID)
        removeContact(localID: localID)
        return true
    }

    /// Re-read one Contacts record addressed by `ContactID` into the cache.
    public func refreshContact(id: ContactID) async {
        guard let localID = contact(id: id)?.localID else { return }
        await refreshContact(localID: localID)
    }

    /// Remove a just-deleted record addressed by `ContactID` from the cache.
    public func removeContact(id: ContactID) {
        guard let localID = contact(id: id)?.localID else { return }
        removeContact(localID: localID)
    }

    /// The reconciled GuessWho UUID carried by `contact` (`ContactID(contact:)
    /// .guessWhoID`), or `nil` when the contact has no valid `guesswho://` URL
    /// yet — NOT the `localID` fallback: an unreconciled contact has no sidecar
    /// data to key on, so callers binding favorites/notes/links/tags must get
    /// `nil` and stand down rather than a transient `localID`.
    ///
    /// A PURE function of the passed contact — no cache read, so no cache-miss
    /// window; it reads the UUID off the live record the caller already holds
    /// via `SidecarKey`, exactly as `Contact.contactID` and `contact(id:)` do.
    /// The sanctioned way for the app to read an OPENED contact's own GuessWho
    /// UUID without reaching into `ContactID.guessWhoID` (which is `package`):
    /// the detail view holds the loaded `Contact` and binds its sidecar stores
    /// on this.
    package func guessWhoID(in contact: Contact) -> String? {
        ContactID(contact: contact).guessWhoID
    }

    /// Debug-only identity diagnostics for an app detail surface. The app may
    /// render these values, but parsing and classification of GuessWho identity
    /// URLs stays in the package.
    public func identityDebugInfo(for contact: Contact) -> ContactIdentityDebugInfo {
        ContactIdentityDebugInfo(
            contactsIdentifier: contact.localID,
            guessWhoID: guessWhoID(in: contact),
            guessWhoURLs: contact.urlAddresses.filter { SidecarKey.parseGuessWhoContactURL($0.value) != nil }
        )
    }

    /// Resolves a BARE GuessWho UUID (a `SidecarKey` endpoint id, a
    /// `Favorite.id`, etc.) to its cached `Contact` via a clean pointer hop:
    /// `guessWhoIDToLocalID[uuid]` → `contactsByLocalID[localID]`. No confirm-
    /// guard is needed — `guessWhoIDToLocalID` is keyed ONLY on real
    /// `guessWhoID`s (unreconciled contacts are excluded), so it can never return
    /// a `localID`-coincidence. Input is lowercased to match the canonical keys
    /// (`SidecarKey` / `Favorite` already lowercase — defensive). Returns `nil`
    /// for an unknown/retired UUID or a string that is only some contact's
    /// `localID` — the "unavailable" contract, never a wrong-contact fallback.
    ///
    /// STAYS PUBLIC: favorites and links sync between devices and so persist the
    /// stable GuessWho UUID (not a `ContactID`, which carries the transient
    /// `localID` and is not `Codable` for that reason). The app reads bare
    /// guessWhoID strings off disk and resolves them here — the bridge that lets
    /// it resolve a link endpoint / favorite without an app-side `uuid → Contact`
    /// map.
    package func contact(guessWhoID: String) -> Contact? {
        guard let lid = guessWhoIDToLocalID[guessWhoID.lowercased()] else { return nil }
        return contactsByLocalID[lid]
    }

    // MARK: - Reconcile-on-write (resolve-or-mint)
    //
    // The INTERNAL plumbing every WRITE entry point (notes/links/favorite)
    // routes through to obtain the GuessWho UUID it writes the sidecar at.
    // Reconcile is a package-INTERNAL side effect of a write: the app never
    // triggers, sees, or names it.

    /// Resolves the GuessWho UUID a sidecar WRITE for `id` must key on, MINTING
    /// one via reconcile IFF the contact has none yet.
    ///
    /// - If `id.guessWhoID` is already present, returns it directly — NO
    ///   reconcile, no re-stamp. An already-reconciled contact's identity is
    ///   stable; a write must not perturb it.
    /// - Otherwise reconcile fires on `id.localID`. With no valid GuessWho URL
    ///   on the contact, reconcile hits Case A and mints a fresh UUID
    ///   (`assignedUUID`). The defensive fall-through re-reads the now-canonical
    ///   record's URL for the pathological Case B/C/D path where reconcile
    ///   stamped a URL without populating `assignedUUID`.
    ///
    /// DEGRADES when the engine is nil (the `.unavailable` storage state): a
    /// write to an unreconciled contact has nowhere to mint, so it THROWS
    /// `SidecarUnavailableError` rather than silently no-op.
    ///
    /// CONCURRENCY — accepts a rare double-mint by design; does NOT serialize.
    /// Two truly-concurrent writes to the SAME never-reconciled `ContactID`
    /// could each mint before the other's write lands: resolve-or-mint must
    /// `await` the reconcile (which `await`s `contacts.fetch`), and the engine's
    /// per-key locks (`PerKeyLockTable`) are SYNCHRONOUS `NSLock`s that CANNOT be
    /// held across that `await`. Accepted as a practical non-event — it needs a
    /// never-reconciled contact AND two simultaneous writes from different
    /// surfaces (effectively only Catalyst multi-window). See the "CONCURRENCY
    /// (decision: ACCEPT double-mint...)" paragraph in
    /// `plans/package-vended-contact-identity.md` for the full rationale,
    /// including why single-device last-write-wins orphans a sidecar (harmless)
    /// and only the multi-device case self-heals via Case-D.
    internal func resolveOrMintGuessWhoID(for id: ContactID) async throws -> String {
        // Fast path: already reconciled — return the stable UUID, mint nothing.
        if let existing = id.guessWhoID {
            return existing
        }
        // Mint path: a write needs the engine. Nil ⇒ no writable sidecar root,
        // so a write cannot proceed (no place to mint or persist) → throw.
        guard let sync else {
            throw SidecarUnavailableError()
        }
        let outcome = try await sync.reconcileContactIdentity(localID: id.localID)
        if let assigned = outcome.assignedUUID {
            return assigned
        }
        // Reconcile finished without an `assignedUUID` — Cases B/C/D may stamp
        // the on-disk URL without populating that field (e.g. a stale in-memory
        // snapshot of a contact that already carried a valid URL). Re-fetch the
        // record so we read the freshly written UUID, via the same `SidecarKey`
        // parser `ContactID` uses.
        if let fresh = try? await contactsStore.fetch(localID: id.localID),
           let stamped = ContactID(contact: fresh).guessWhoID {
            return stamped
        }
        throw ReconcileAssignmentFailedError()
    }

    // MARK: - ContactID-keyed contact API (notes / links / favorites)
    //
    // The PUBLIC contact-sidecar surface the app speaks, keyed exclusively on
    // `ContactID`. Plain verbs, no "sidecar" in any name: the app never
    // constructs a `SidecarKey` — the repository translates a `ContactID` to
    // `SidecarKey(kind: .contact, id: guessWhoID)` internally and calls the
    // engine.
    //
    // READS never reconcile: `id.guessWhoID` is already on the value. An
    // UNRECONCILED contact (`id.guessWhoID == nil`) has no sidecar yet, so
    // reads return empty/false and MINT NOTHING. Single-envelope reads
    // (notes/fields) are synchronous; the LINK reads are `async` because they
    // walk every link sidecar on disk and must not block the main actor.
    //
    // WRITES are `async`: they resolve-or-mint the GuessWho UUID first (via
    // `resolveOrMintGuessWhoID`, which `await`s reconcile), call the engine,
    // then — if the resolve MINTED — refresh the affected contact so the app
    // needs no post-write reload. When the engine (or, for favorites, the
    // favorites store) is nil — the `.unavailable` storage state — writes THROW
    // `SidecarUnavailableError` rather than silently no-op.

    /// Live (non-deleted) notes on the contact identified by `id`, oldest first.
    /// Returns `[]` when the contact is unreconciled (no sidecar yet) or the
    /// engine is unavailable; a read NEVER reconciles. Mirrors
    /// `SyncService.notes(forContactUUID:)`.
    public func notes(for id: ContactID) -> [ContactNote] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        do {
            return try sync.notes(at: SidecarKey(kind: .contact, id: guessWhoID))
        } catch {
            lastError = "notes read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// ALL notes on the contact identified by `id` — INCLUDING soft-deleted
    /// tombstones (`deletedAt` set). For inspection/recovery surfaces (the
    /// Recently Deleted screen, the agent audit trail) where the tombstones
    /// are the point; ordinary UI reads want `notes(for:)`. Returns `[]` when
    /// the contact is unreconciled or the engine is unavailable; a read NEVER
    /// reconciles. Mirrors `GuessWhoSync.allNotes(at:)`.
    public func allNotes(for id: ContactID) -> [ContactNote] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        do {
            return try sync.allNotes(at: SidecarKey(kind: .contact, id: guessWhoID))
        } catch {
            lastError = "all-notes read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// ALL sidecar fields on the contact identified by `id` — INCLUDING
    /// soft-deleted tombstones and `.blob` infrastructure fields. For
    /// inspection/recovery surfaces only (the Recently Deleted screen needs a
    /// deleted field's preserved value and its `modifiedAt` for the restore
    /// guard); the user-visible custom-fields read is `fields(for:)`. Returns
    /// `[]` when the contact is unreconciled or the engine is unavailable.
    public func allFields(for id: ContactID) -> [SidecarField] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        do {
            return try sync.fields(at: SidecarKey(kind: .contact, id: guessWhoID))
        } catch {
            lastError = "all-fields read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// A single link by its own UUID, INCLUDING a soft-deleted one (callers
    /// inspect `deletedAt`). For recovery surfaces (a deleted link's preserved
    /// note is the restore payload); the per-contact list reads above filter
    /// tombstones. Returns nil when the link doesn't exist or the engine is
    /// unavailable. Mirrors `GuessWhoSync.link(id:)`.
    public func link(id linkID: UUID) -> Link? {
        guard let sync else { return nil }
        do {
            return try sync.link(id: linkID)
        } catch {
            lastError = "link read failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Live contact↔contact links on the contact identified by `id`. Excludes
    /// soft-deleted links and links whose FAR endpoint is not a contact (those
    /// are event links — see `eventLinks(for:)`). Returns `[]` when the contact
    /// is unreconciled or the engine is unavailable. Mirrors
    /// `SyncService.contactLinks(forContactUUID:)`.
    ///
    /// `async` — unlike the single-envelope reads above, the link read walks
    /// EVERY link sidecar on disk, so it rides the engine's background-hop
    /// overload rather than blocking the main actor. Same for
    /// `eventLinks(for:)` / `linkedEventUUIDs(for:)` below.
    public func links(for id: ContactID) async -> [Link] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        do {
            return try await sync.links(at: endpoint).filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .contact
            }
        } catch {
            lastError = "links read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Live contact↔event links on the contact identified by `id`. Excludes
    /// soft-deleted links and links whose FAR endpoint is not an event. Returns
    /// `[]` when the contact is unreconciled or the engine is unavailable.
    /// Mirrors `SyncService.eventLinks(forContactUUID:)`. (The CONTACT endpoint
    /// is keyed on `ContactID`; the EVENT endpoint stays a bare UUID until the
    /// deferred event-identity migration.)
    public func eventLinks(for id: ContactID) async -> [Link] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        do {
            return try await sync.links(at: endpoint).filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .event
            }
        } catch {
            lastError = "event links read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// The bare EVENT-endpoint UUIDs of every live contact↔event link on the
    /// contact identified by `id`. The package resolves the far (event) endpoint
    /// internally so the app never constructs a `.contact` `SidecarKey` to walk a
    /// link — it hands its `ContactID` and gets back the event UUIDs to feed the
    /// event surface's refresh (still on `SyncService`). Returns `[]` when the
    /// contact is unreconciled or the engine is unavailable. (The EVENT endpoint
    /// stays a bare UUID until the deferred event-identity migration.)
    public func linkedEventUUIDs(for id: ContactID) async -> [String] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        do {
            return try await sync.links(at: endpoint).compactMap { link in
                guard link.deletedAt == nil else { return nil }
                let other = Self.otherEndpoint(of: link, from: endpoint)
                return other.kind == .event ? other.id : nil
            }
        } catch {
            lastError = "linked event UUIDs read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// The bare EVENT-endpoint UUID of a single contact↔event `link`, relative to
    /// the contact identified by `id`. The package classifies the link's
    /// endpoints internally (resolving `id` to the contact endpoint) so a row
    /// rendering one linked event never constructs a `.contact` `SidecarKey`.
    /// Returns `nil` when the contact is unreconciled (it can hold no link) or
    /// when neither endpoint is the contact (defensive). The EVENT endpoint stays
    /// a bare UUID until the deferred event-identity migration.
    public func eventEndpointUUID(of link: Link, for id: ContactID) -> String? {
        guard let guessWhoID = id.guessWhoID else { return nil }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        let other = Self.otherEndpoint(of: link, from: endpoint)
        return other.kind == .event ? other.id : nil
    }

    /// The far CONTACT endpoint of a contact↔contact `link`, relative to the
    /// contact identified by `id`. The app gets the resolved `Contact` without
    /// reading the far endpoint's bare GuessWho UUID.
    public func linkedContact(of link: Link, for id: ContactID) -> Contact? {
        guard let guessWhoID = id.guessWhoID else { return nil }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        guard link.endpointA == endpoint || link.endpointB == endpoint else { return nil }
        let other = Self.otherEndpoint(of: link, from: endpoint)
        return other.kind == .contact ? contact(guessWhoID: other.id) : nil
    }

    /// The CONTACT endpoint of a contact↔event `link`, relative to the event
    /// sidecar UUID. The event UUID remains the deferred EventID migration's
    /// boundary; the contact endpoint UUID stays inside the package.
    public func linkedContact(of link: Link, forEventUUID eventUUID: String) -> Contact? {
        let endpoint = SidecarKey(kind: .event, id: eventUUID)
        return linkedContact(of: link, at: endpoint)
    }

    /// The far CONTACT endpoint of `link`, relative to any non-contact
    /// sidecar endpoint (currently an event or place). This keeps the bare
    /// GuessWho contact UUID inside the package while allowing generic entity
    /// detail pages to resolve their linked contact.
    public func linkedContact(of link: Link, at endpoint: SidecarKey) -> Contact? {
        guard link.endpointA == endpoint || link.endpointB == endpoint else { return nil }
        let other = Self.otherEndpoint(of: link, from: endpoint)
        return other.kind == .contact ? contact(guessWhoID: other.id) : nil
    }

    /// Whether the contact identified by `id` is favorited. Returns `false` when
    /// the contact is unreconciled (no GuessWho UUID to key the favorite on) or
    /// the favorites store is unavailable. Mirrors
    /// `SyncService.isFavorite(kind: .contact, id:)`.
    public func isFavorite(_ id: ContactID) -> Bool {
        guard let favorites, let guessWhoID = id.guessWhoID else { return false }
        do {
            return try favorites.isFavorite(kind: .contact, id: guessWhoID)
        } catch {
            lastError = "favorites lookup failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Look up a cached `ContactGroup` by its Contacts `localID`, matched
    /// case-insensitively because favorites persist the `localID` lowercased
    /// (see `Favorite.id`) while `CNGroup.identifier` is mixed-case. Reads the
    /// `groups` cache filled by `loadGroups()`; returns nil until that lands or
    /// when the group no longer exists.
    public func group(localID: String) -> ContactGroup? {
        let needle = localID.lowercased()
        return groups.first { $0.localID.lowercased() == needle }
    }

    /// Project persisted favorites into app-facing rows without exposing contact
    /// favorite UUIDs. Contact favorites resolve through this repository's
    /// GuessWhoID index; event favorites use the supplied resolver until the
    /// deferred EventID migration moves event identity behind the package too;
    /// group favorites resolve against the `groups` cache (case-insensitively —
    /// see `group(localID:)`).
    public func favoriteListItems(
        from favorites: [Favorite],
        event: (String) -> Event?
    ) -> [FavoriteListItem] {
        favorites.map { favorite in
            switch favorite.kind {
            case .contact:
                FavoriteListItem(
                    id: FavoriteListItem.ID(favorite.stableID),
                    kind: favorite.kind,
                    contact: contact(guessWhoID: favorite.id)
                )
            case .event:
                FavoriteListItem(
                    id: FavoriteListItem.ID(favorite.stableID),
                    kind: favorite.kind,
                    event: event(favorite.id)
                )
            case .group:
                FavoriteListItem(
                    id: FavoriteListItem.ID(favorite.stableID),
                    kind: favorite.kind,
                    group: group(localID: favorite.id)
                )
            }
        }
    }

    /// Append a note to the contact identified by `id`, returning the new note's
    /// UUID. Resolves-or-mints the GuessWho UUID first (the FIRST write to an
    /// unreconciled contact reconciles + mints, transparent to the caller), then
    /// writes the note, then refreshes the cache if the write minted (decision
    /// B). Throws `SidecarUnavailableError` when the engine is unavailable.
    /// Mirrors `SyncService.addNote(body:forContactUUID:)`.
    @discardableResult
    public func addNote(for id: ContactID, body: String, createdAt: Date = Date()) async throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let noteID = try sync.addNote(
            at: SidecarKey(kind: .contact, id: guessWhoID),
            body: body,
            createdAt: createdAt
        )
        await refreshCacheIfMinted(minted, localID: id.localID)
        return noteID
    }

    // MARK: - Contact timestamp stamps (reconcile-on-write)
    //
    // Each stamp upserts ONE named timestamp cell on the contact sidecar and,
    // like every other write here, resolves-or-mints the GuessWho UUID first —
    // so the FIRST stamp to an unreconciled contact reconciles + mints, then
    // refreshes the cache. The three stamps differ only in which cell they
    // target.

    /// Stamp `lastModified = now` on the contact identified by `id`. Mirrors
    /// `addNote`: resolve-or-mint, write the cell, refresh on mint.
    public func stampModified(_ id: ContactID) async throws {
        try await stampTimestamp(.modified, for: id)
    }

    /// Stamp `lastInteracted = now` on the contact identified by `id`. Mirrors
    /// `addNote`: resolve-or-mint, write the cell, refresh on mint.
    public func stampInteracted(_ id: ContactID) async throws {
        try await stampTimestamp(.interacted, for: id)
    }

    /// Stamp `lastViewed = now` on the contact identified by `id`. The
    /// "always reconcile when stamping viewed" reconcile happens INSIDE
    /// `resolveOrMintGuessWhoID(for:)` — an unreconciled contact mints its
    /// GuessWho UUID as part of this write. Mirrors `addNote`: resolve-or-mint,
    /// write the cell, refresh on mint.
    public func stampViewed(_ id: ContactID) async throws {
        try await stampTimestamp(.viewed, for: id)
    }

    /// Shared body of the three stamp verbs. Throws `SidecarUnavailableError`
    /// when the engine is unavailable; otherwise resolves-or-mints the GuessWho
    /// UUID (reconciling an unreconciled contact), writes the one timestamp
    /// cell at `now`, and refreshes the cache if the resolve minted.
    private func stampTimestamp(_ which: ContactTimestampKind, for id: ContactID) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let key = SidecarKey(kind: .contact, id: guessWhoID)
        let now = Date()
        try sync.stampContactTimestamp(which, at: key, now: now)
        // The write touched exactly ONE cell and `now` IS its new value, so
        // update that one cache entry in place. A wholesale
        // `refreshTimestampCache()` here would re-read every contact sidecar
        // off disk on the main actor — on every contact open (stampViewed) —
        // which is the I/O stall this in-place update exists to avoid.
        // External edits still land via the change-notification reload path.
        updateTimestampCache(which, at: key, to: now)
        await refreshCacheIfMinted(minted, localID: id.localID)
        // On mint, `refreshCacheIfMinted` posts its own reload; on the common
        // non-mint path, post so a time-ordered list re-renders. A stamp only
        // moves a timestamp — the contact records themselves are untouched.
        if !minted { postDidReload(contactDataChanged: false) }
    }

    /// Upsert the single `which` timestamp on the cache entry for `key`,
    /// leaving the other two timestamps untouched — the in-memory mirror of
    /// what `stampContactTimestamp` just wrote to disk. Keyed on `key.id`, the
    /// same canonical-lowercase UUID `allContactTimestamps()` keys on.
    private func updateTimestampCache(_ which: ContactTimestampKind, at key: SidecarKey, to now: Date) {
        var stamps = contactTimestampsByID[key.id] ?? ContactTimestamps()
        switch which {
        case .modified: stamps.lastModified = now
        case .interacted: stamps.lastInteracted = now
        case .viewed: stamps.lastViewed = now
        }
        contactTimestampsByID[key.id] = stamps
    }

    /// All live (non-deleted) USER-VISIBLE sidecar fields on the contact, by
    /// `ContactID`. Returns empty for an unreconciled id (no mint on read).
    ///
    /// `.blob` fields are EXCLUDED: they are internal infrastructure (e.g. the
    /// `previousPhoto` snapshot), not user-editable fields. Surfacing one would
    /// render a phantom row (literally "previousPhoto") in the custom-fields UI
    /// — a product-principle violation. The surface is text/date/checkbox only;
    /// blobs are read through their own typed accessors
    /// (`GuessWhoSync.blobFieldData`).
    public func fields(for id: ContactID) -> [SidecarField] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let all = (try? sync.fields(at: SidecarKey(kind: .contact, id: guessWhoID))) ?? []
        return all.filter { $0.deletedAt == nil && $0.type != .blob }
    }

    /// Upsert a named free-text sidecar field on the contact, by `field` name:
    ///  - no existing field → create it with `type`;
    ///  - existing field, SAME type → update its value in place;
    ///  - existing field, DIFFERENT type → replace it (delete + recreate) so the
    ///    type can change. The per-cell type is write-once in the UI, but a
    ///    programmatic replace is allowed — e.g. an import upgrading a single-
    ///    line `.note` to a `.multilineNote`.
    ///
    /// Gives stable, re-importable key/value storage (unlike notes, which
    /// append). Resolves-or-mints first, then refreshes the cache if minted.
    /// Returns the field's id. Throws `SidecarUnavailableError` if no engine.
    @discardableResult
    public func upsertField(
        for id: ContactID,
        field: String,
        value: String,
        type: SidecarFieldType = .note
    ) async throws -> UUID {
        try await upsertField(for: id, field: field, value: JSONValue.string(value), type: type)
    }

    /// `JSONValue` overload of `upsertField(for:field:value:type:)` for the
    /// non-string payload types (`.checkbox` carries a JSON bool). The String
    /// overload above delegates here; the engine's `validate(value:against:)`
    /// still enforces the payload/type pairing.
    @discardableResult
    public func upsertField(
        for id: ContactID,
        field: String,
        value: JSONValue,
        type: SidecarFieldType
    ) async throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let key = SidecarKey(kind: .contact, id: guessWhoID)

        let existing = ((try? sync.fields(at: key)) ?? [])
            .first { $0.deletedAt == nil && $0.field == field }

        let fieldID: UUID
        if let existing, existing.type == type {
            // Same type — update in place.
            try sync.setField(at: key, id: existing.id, field: field, value: value)
            fieldID = existing.id
        } else {
            // Different type (or new) — replace: soft-delete the old, create new.
            if let existing {
                try sync.deleteField(at: key, id: existing.id)
            }
            fieldID = try sync.addField(at: key, field: field, type: type, value: value)
        }
        await refreshCacheIfMinted(minted, localID: id.localID)
        return fieldID
    }

    /// Edit an existing sidecar field's value (by field id) on the contact.
    /// `id` is the CONTACT, `fieldID` the field. Silent no-op if the field is
    /// gone. Throws `SidecarUnavailableError` if no engine.
    public func editField(for id: ContactID, id fieldID: UUID, value: String) async throws {
        try await editField(for: id, id: fieldID, value: JSONValue.string(value))
    }

    /// `JSONValue` overload of `editField(for:id:value:)` for non-string
    /// payload types (a `.checkbox` field's value is a JSON bool). The
    /// Recently Deleted restore rides this with the tombstone's own
    /// preserved value, so any field type restores verbatim; the engine
    /// still validates the payload against the cell's immutable type. The
    /// String overload above delegates here.
    public func editField(for id: ContactID, id fieldID: UUID, value: JSONValue) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        // setField needs the field's current name (it's preserved); read it.
        let key = SidecarKey(kind: .contact, id: guessWhoID)
        let name = ((try? sync.fields(at: key)) ?? []).first { $0.id == fieldID }?.field
        if let name {
            try sync.setField(at: key, id: fieldID, field: name, value: value)
        }
        await refreshCacheIfMinted(minted, localID: id.localID)
    }

    /// Soft-delete a sidecar field (by field id) on the contact. `id` is the
    /// CONTACT, `fieldID` the field. Throws `SidecarUnavailableError` if no engine.
    public func deleteField(for id: ContactID, id fieldID: UUID) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        try sync.deleteField(at: SidecarKey(kind: .contact, id: guessWhoID), id: fieldID)
        await refreshCacheIfMinted(minted, localID: id.localID)
    }

    /// Edit an existing note's body on the contact identified by `id`. The two
    /// `id`s are disambiguated: `id` is the CONTACT, `noteID` is the note. (An
    /// edit can't mint — a note can only exist on an already-reconciled contact
    /// — but resolve-or-mint is still routed for consistency with the other
    /// writes, and the cache refreshed in that impossible case for safety.)
    /// Throws when the engine is unavailable. Mirrors
    /// `SyncService.editNote(id:newBody:forContactUUID:)`.
    public func editNote(for id: ContactID, id noteID: UUID, newBody: String, createdAt: Date? = nil) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        try sync.editNote(
            at: SidecarKey(kind: .contact, id: guessWhoID),
            id: noteID,
            newBody: newBody,
            createdAt: createdAt
        )
        await refreshCacheIfMinted(minted, localID: id.localID)
    }

    /// Soft-delete a note on the contact identified by `id`. `id` is the
    /// CONTACT, `noteID` the note. Throws when the engine is unavailable.
    /// Mirrors `SyncService.deleteNote(id:forContactUUID:)`.
    public func deleteNote(for id: ContactID, id noteID: UUID) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        try sync.deleteNote(at: SidecarKey(kind: .contact, id: guessWhoID), id: noteID)
        await refreshCacheIfMinted(minted, localID: id.localID)
    }

    /// Create a durable contact↔contact link between `a` and `b`, returning the
    /// minted `Link`. Resolves-or-mints BOTH endpoints first (so the link is
    /// keyed on their canonical GuessWho UUIDs even if either was unreconciled),
    /// then writes the link, then refreshes the cache for whichever endpoint(s)
    /// minted. Throws `SidecarUnavailableError` when the engine is unavailable.
    /// Mirrors `SyncService.addContactLink(fromUUID:toUUID:note:)`.
    @discardableResult
    public func addLink(from a: ContactID, to b: ContactID, note: String) async throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        let aMinted = a.guessWhoID == nil
        let bMinted = b.guessWhoID == nil
        let aID = try await resolveOrMintGuessWhoID(for: a)
        let bID = try await resolveOrMintGuessWhoID(for: b)
        let link = try sync.addLink(
            from: SidecarKey(kind: .contact, id: aID),
            to: SidecarKey(kind: .contact, id: bID),
            note: note
        )
        await refreshCacheIfMinted(aMinted, localID: a.localID)
        await refreshCacheIfMinted(bMinted, localID: b.localID)
        return link
    }

    /// Mutate the note on an existing link. The link is identified by its own
    /// UUID (`linkID`), so no contact resolve-or-mint is needed — but it is a
    /// WRITE, so it throws `SidecarUnavailableError` when the engine is
    /// unavailable, consistent with the other writes. Mirrors
    /// `SyncService.setContactLinkNote(id:note:)`.
    public func setLinkNote(id linkID: UUID, note: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.setLinkNote(id: linkID, note: note)
    }

    /// Soft-delete a link by its own UUID. No contact resolve-or-mint needed;
    /// throws `SidecarUnavailableError` when the engine is unavailable. Mirrors
    /// `SyncService.removeContactLink(id:)` (and the shared `removeLink(id:)`).
    public func removeLink(id linkID: UUID) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.removeLink(id: linkID)
    }

    /// Create a durable contact↔event link between the contact identified by
    /// `id` and the event identified by `eventUUID`, returning the minted
    /// `Link`. Resolves-or-mints the CONTACT endpoint; the EVENT endpoint is a
    /// bare UUID (`SidecarKey(kind: .event, id: eventUUID)`) until the deferred
    /// event-identity migration. Refreshes the cache if the contact minted.
    /// Throws `SidecarUnavailableError` when the engine is unavailable. Mirrors
    /// `SyncService.addContactEventLink(contactUUID:eventUUID:note:)`.
    @discardableResult
    public func addEventLink(for id: ContactID, eventUUID: String, note: String) async throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let link = try sync.addLink(
            from: SidecarKey(kind: .contact, id: guessWhoID),
            to: SidecarKey(kind: .event, id: eventUUID),
            note: note
        )
        await refreshCacheIfMinted(minted, localID: id.localID)
        return link
    }

    /// Create a durable contact↔place link. As with `addEventLink`, the
    /// CONTACT endpoint resolves-or-mints internally while the already-stored
    /// PLACE endpoint is addressed by its sidecar UUID.
    @discardableResult
    public func addPlaceLink(for id: ContactID, placeUUID: String, note: String) async throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let link = try sync.addLink(
            from: SidecarKey(kind: .contact, id: guessWhoID),
            to: SidecarKey(kind: .place, id: placeUUID),
            note: note
        )
        await refreshCacheIfMinted(minted, localID: id.localID)
        return link
    }

    /// Toggle the favorite state of the contact identified by `id`, returning
    /// the NEW state (`true` if just favorited, `false` if unfavorited).
    /// Resolves-or-mints the GuessWho UUID first (favoriting a never-touched
    /// contact reconciles + mints, transparent to the caller), then toggles the
    /// CONTACT favorite, then refreshes the cache if it minted. Throws
    /// `SidecarUnavailableError` when EITHER the engine (needed to mint) OR the
    /// favorites store is unavailable. Mirrors
    /// `SyncService.toggleFavorite(kind: .contact, id:)`.
    @discardableResult
    public func toggleFavorite(_ id: ContactID) async throws -> Bool {
        guard let favorites else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let newState = try favorites.toggle(kind: .contact, id: guessWhoID, now: Date())
        await refreshCacheIfMinted(minted, localID: id.localID)
        return newState
    }

    // MARK: - Decision B helper
    //
    // Notes/links/favorite writes do NOT alter the cached `Contact` — they live
    // in the sidecar / favorites file, not on the `CNContact`. The ONLY write
    // that changes the cached Contact is the FIRST write to an unreconciled
    // contact, where resolve-or-mint stamped a fresh `guesswho://` URL onto its
    // `urlAddresses` (changing its `guessWhoID`, hence its effective identity).
    // In that case only, re-read the one record so the cache reflects the new
    // identity and the app needs no post-write reload: `refreshContact(localID:)`
    // re-fetches it and rebuilds the indexes, re-keying it under the new
    // effective id. When nothing minted, the cached Contact is unchanged and we
    // skip the fetch.

    /// Re-read the one record into the cache iff the preceding resolve-or-mint
    /// minted a UUID (the contact's `guessWhoID` was nil going in). No-op
    /// otherwise — the cached `Contact` is untouched by a sidecar/favorite write.
    private func refreshCacheIfMinted(_ minted: Bool, localID: String) async {
        guard minted else { return }
        await refreshContact(localID: localID)
    }

    /// Far endpoint of `link` relative to `endpoint` (the one that is NOT
    /// `endpoint`). Used to classify a link as contact↔contact vs contact↔event
    /// by inspecting the FAR endpoint's `kind`. Mirrors
    /// `SyncService.otherEndpoint(of:from:)`.
    private static func otherEndpoint(of link: Link, from endpoint: SidecarKey) -> SidecarKey {
        link.endpointA == endpoint ? link.endpointB : link.endpointA
    }

    /// People rows addressed by `ContactID`, sectioned A–Z. Mirrors
    /// `peopleSections`. EVERY cached person yields a row — a contact without a
    /// GuessWho URL is still vended, identified by its `localID` fallback, so
    /// nothing is silently dropped before reconciliation runs.
    public var peopleSectionIDs: [(String, [ContactID])] { sectionedIDs(people) }

    /// Organization rows addressed by `ContactID`, sectioned A–Z. Mirrors
    /// `organizationsSections`.
    public var organizationsSectionIDs: [(String, [ContactID])] { sectionedIDs(organizations) }

    /// Every cached contact whose display name matches `displayName`, addressed
    /// by `ContactID`. Returns ALL matches (no silent last-writer pick) — the
    /// UI owns disambiguation. The `ContactID` parallel to `contacts(named:)`.
    public func contactIDs(named displayName: String) -> [ContactID] {
        contacts(named: displayName).map { ContactID(contact: $0) }
    }

    /// Cached contacts that list `email` among their addresses, addressed by
    /// `ContactID`. Matching is case-insensitive on the trimmed address; an
    /// empty query returns nothing. Returns ALL matches. Named `contactIDs(...)`
    /// for consistency with `contactIDs(named:)`.
    public func contactIDs(matchingEmail email: String) -> [ContactID] {
        let needle = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        // O(1) index hit. `contactsByEmail` lists matches in cache-array order
        // (the funnel appends per contact as it walks the array), preserving the
        // previous `contacts.compactMap` ordering.
        return (contactsByEmail[needle] ?? []).map { ContactID(contact: $0) }
    }

    /// Cached contacts whose stored LinkedIn URL matches `linkedInURL`, by either
    /// canonical-URL or slug equality (see `LinkedInURL.sameProfile`). Scans each
    /// contact's `socialProfiles` (urlString/username) and `urlAddresses` for a
    /// LinkedIn link. A LinkedIn URL is a near-unique identifier, so this is the
    /// most precise match signal. Returns ALL matches; empty query returns none.
    /// O(n) scan — fine for a one-shot, user-initiated match.
    public func contactIDs(matchingLinkedInURL linkedInURL: String) -> [ContactID] {
        let needle = linkedInURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, LinkedInURL.slug(from: needle) != nil else { return [] }
        return contacts.filter { contact in
            // socialProfiles: a LinkedIn entry stores the URL and/or username.
            let socialHit = contact.socialProfiles.contains { lp in
                let p = lp.value
                if !p.urlString.isEmpty, LinkedInURL.sameProfile(p.urlString, needle) { return true }
                if !p.username.isEmpty, let s = LinkedInURL.slug(from: needle), p.username.lowercased() == s.lowercased() { return true }
                return false
            }
            if socialHit { return true }
            // urlAddresses: a stored LinkedIn website link.
            return contact.urlAddresses.contains { lv in
                LinkedInURL.isLinkedIn(lv.value) && LinkedInURL.sameProfile(lv.value, needle)
            }
        }.map { ContactID(contact: $0) }
    }

    /// Single package entry point for matching a parsed LinkedIn profile to an
    /// existing contact. Runs the tiers in precision order and returns the FIRST
    /// non-empty tier (the app owns disambiguation when a tier returns several):
    ///   1. LinkedIn URL (profileUrl / sourceUrl) — most precise
    ///   2. any parsed email
    ///   3. display name (fullName)
    /// Returns an empty array when nothing matches.
    public func matchLinkedIn(profile: LinkedInProfile) -> [ContactID] {
        // 1. LinkedIn URL — try the contact-info profile URL, then the page URL.
        for url in [profile.contactInfo?.profileUrl, profile.sourceUrl].compactMap({ $0 }) {
            let hits = contactIDs(matchingLinkedInURL: url)
            if !hits.isEmpty { return hits }
        }
        // 2. Email — any parsed email.
        for email in profile.contactInfo?.emails ?? [] {
            let hits = contactIDs(matchingEmail: email)
            if !hits.isEmpty { return hits }
        }
        // 3. Display name.
        if let name = profile.fullName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hits = contactIDs(named: name)
            if !hits.isEmpty { return hits }
        }
        return []
    }

    /// Cached contacts that reference the contact identified by `id` through a
    /// name-only `CNContactRelation`, addressed by `ContactID`. Self is excluded
    /// by EFFECTIVE identity (`guessWhoID ?? localID`) — never by raw `localID` —
    /// so a contact that relates to its own name doesn't appear in its own
    /// reverse-relation list.
    public func contactsReferencing(id: ContactID) -> [(id: ContactID, label: String)] {
        // ContactID is identity-only, so resolve it to its cached Contact (O(1)
        // index hit) to read the display name we match relations against.
        guard let needle = contact(id: id)?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !needle.isEmpty else { return [] }
        return contacts.flatMap { other -> [(id: ContactID, label: String)] in
            let otherID = ContactID(contact: other)
            guard otherID.effectiveID != id.effectiveID else { return [] }
            return other.contactRelations.compactMap { relation in
                let name = relation.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return name == needle ? (id: otherID, label: relation.label) : nil
            }
        }
    }

    public var people: [Contact] {
        filtered(matching: peopleSearch, where: {
            $0.contactType == .person && matchesLinkFilter(peopleFilter, contact: $0)
        })
    }

    public var organizations: [Contact] {
        filtered(matching: organizationsSearch, where: {
            $0.contactType == .organization && matchesLinkFilter(organizationsFilter, contact: $0)
        })
    }

    private func matchesLinkFilter(_ filter: LinkFilter, contact: Contact) -> Bool {
        switch filter {
        case .all:
            return true
        case .linked:
            guard let guessWhoID = ContactID(contact: contact).guessWhoID else { return false }
            return linkedContactIDs.contains(SidecarKey(kind: .contact, id: guessWhoID).id)
        }
    }

    /// Number of live links touching `contact` (any far-endpoint kind), for the
    /// "N links" list badge. Zero for an unreconciled contact (no GuessWho UUID)
    /// or one with no links; callers hide the badge on zero. Keyed the same way
    /// as `matchesLinkFilter`'s Linked case so the badge and the filter agree.
    public func linkCount(for contact: Contact) -> Int {
        guard let guessWhoID = ContactID(contact: contact).guessWhoID else { return 0 }
        return linkCountsByID[SidecarKey(kind: .contact, id: guessWhoID).id] ?? 0
    }

    public var peopleSections: [(String, [Contact])] { sectioned(people) }
    public var organizationsSections: [(String, [Contact])] { sectioned(organizations) }

    /// Test seam: the People sections computed against an INJECTED `now` so the
    /// relative-time bucketing of a time `sortOrder` is deterministic. The
    /// public `peopleSections` is this with `now = Date()`. Not for app use —
    /// the bucket boundaries should always be "now" in production.
    func peopleSections(now: Date) -> [(String, [Contact])] { sectioned(people, now: now) }

    /// Transitional compatibility lookup. Duplicate display names collapse to
    /// the last cached contact; new callers should use `contacts(named:)`.
    public func lookupByDisplayName() -> [String: Contact] {
        var map: [String: Contact] = [:]
        for contact in contacts {
            let key = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            map[key] = contact
        }
        return map
    }

    /// Returns every cached contact whose display name matches `displayName`.
    /// Unlike the legacy `lookupByDisplayName()`, this preserves ambiguity.
    public func contacts(named displayName: String) -> [Contact] {
        let needle = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contacts.filter {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    public func contactsReferencing(contact: Contact) -> [(contact: Contact, label: String)] {
        let needle = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contacts.flatMap { other in
            guard other.localID != contact.localID else {
                return [(contact: Contact, label: String)]()
            }
            return other.contactRelations.compactMap { relation in
                let name = relation.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return name == needle ? (contact: other, label: relation.label) : nil
            }
        }
    }

    /// The cached organization record (`contactType == .organization`) whose
    /// display name matches `name` (trimmed, case-insensitive). This is the
    /// INFERRED person→organization association — a person's Contacts
    /// "company" string pointing at an organization record by name; no
    /// sidecar link is involved. Ambiguity (several organizations sharing
    /// the name) resolves to the first in cache order, mirroring the
    /// relation-row lookup. nil when `name` is blank or nothing matches.
    public func organizationContact(named name: String) -> Contact? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return contacts.first { other in
            other.contactType == .organization &&
                other.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    /// People whose Contacts "company" field matches `organization`'s display
    /// name (trimmed, case-insensitive) — the inverse of
    /// `organizationContact(named:)`. Inferred association only (no sidecar
    /// link), people only, sorted by display name.
    public func contactsAssociated(with organization: Contact) -> [Contact] {
        let needle = organization.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contacts
            .filter { person in
                person.contactType == .person &&
                    person.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The distinct department names carried by the people associated with
    /// `organization` (see `contactsAssociated(with:)`). Trimmed; blank
    /// departments excluded; de-duplicated case-insensitively (the first-seen
    /// display form wins); sorted A–Z. Empty when the organization has no
    /// associated people or none of them names a department.
    public func departments(in organization: Contact) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for person in contactsAssociated(with: organization) {
            let name = person.departmentName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The people associated with `organization` (see
    /// `contactsAssociated(with:)`) whose Contacts "department" field matches
    /// `department` (trimmed, case-insensitive). A subset of
    /// `contactsAssociated(with:)`, sorted by display name.
    public func contactsAssociated(with organization: Contact, inDepartment department: String) -> [Contact] {
        let needle = department.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contactsAssociated(with: organization).filter { person in
            person.departmentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    /// Renames a department across the organization's people: every person
    /// associated with `organization` (see `contactsAssociated(with:)`) whose
    /// Contacts "department" field currently matches `oldName` (trimmed,
    /// case-insensitive) has that field rewritten to `newName` (trimmed). Each
    /// matching Contacts record is re-fetched fresh (see `editableContact(id:)`
    /// for why the fresh path beats the bulk cache right after a write), edited,
    /// and saved; the edited records are then refreshed into the cache in ONE
    /// commit and a single reload is posted. Returns the number of records
    /// updated.
    ///
    /// `newName` is trimmed and, when blank, the rename is a no-op returning 0 —
    /// callers should still disable their Save affordance on an empty field, but
    /// this keeps the invariant "a department never becomes nameless" at the
    /// package boundary too. A write that throws (e.g. Contacts authorization
    /// denied) propagates; records saved before the failure keep their new name.
    @discardableResult
    public func renameDepartment(from oldName: String, to newName: String, in organization: Contact) async throws -> Int {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return 0 }
        let matches = contactsAssociated(with: organization, inDepartment: oldName)
        guard !matches.isEmpty else { return 0 }

        var editedLocalIDs: [String] = []
        for match in matches {
            // Fetch fresh for a reliable record; skip a record that vanished
            // between the cache read and the write.
            guard var fresh = try await contactsStore.fetch(localID: match.localID) else { continue }
            fresh.departmentName = trimmedNew
            Self.saveLog.notice("contact save requested", metadata: [
                "op": "renameDepartment", "localID": .string(fresh.localID),
            ])
            try await contactsStore.save(fresh)
            editedLocalIDs.append(fresh.localID)
        }

        // Refresh every edited record into one working copy so the indexes
        // rebuild exactly once, then post a single reload.
        var working = contacts
        for localID in editedLocalIDs {
            await refetch(localID: localID, into: &working)
        }
        setContacts(working)
        postDidReload()
        return editedLocalIDs.count
    }

    /// Re-read one Contacts record and reconcile it into the cache.
    package func refreshContact(localID: String) async {
        await applyRefresh(localID: localID)
        postDidReload()
    }

    /// Remove a just-deleted record from the in-memory cache.
    package func removeContact(localID: String) {
        var updated = contacts
        updated.removeAll { $0.localID == localID }
        setContacts(updated)
        postDidReload()
    }

    private func postDidReload(contactDataChanged: Bool = true) {
        // Routed through the injected center (defaults to `.default`, so the
        // app's list controllers still observe it). Outbound reload and inbound
        // change observer share one center, so a test on a fresh center sees only
        // its own repository's reload. `object: self` already scopes this signal
        // per-repository; the injected center is what isolates the inbound
        // `object: nil` change observer (see init).
        //
        // `contactDataChanged: false` marks a presentation-only post (sort
        // flip, timestamp stamp, groups refresh) so data-keyed caches — the
        // app's decoded-photo cache in particular — can skip a wholesale
        // invalidation. Defaults to `true`: any site that isn't POSITIVE the
        // records are untouched must let consumers invalidate.
        notificationCenter.post(
            name: .contactsRepositoryDidReload,
            object: self,
            userInfo: [ContactsRepositoryDidReloadKey.contactDataChanged: contactDataChanged]
        )
    }

    /// The SINGLE funnel for every `contacts` mutation. Reassigns the array
    /// (preserving `@Observable` tracking) and rebuilds all three point-lookup
    /// indexes from the new array so they can never drift from it. Incremental
    /// sites (refresh / remove / delta-apply) mutate a local copy and call this
    /// once; a wholesale rebuild at v1 address-book scale is cheap and rules out
    /// patch-drift bugs — including the reconciliation re-key, which is automatic
    /// here because the new array yields the new effective-id key and never
    /// reproduces the stale one.
    private func setContacts(_ newValue: [Contact]) {
        contacts = newValue

        var byLocalID: [String: Contact] = [:]
        var byGuessWhoID: [String: String] = [:]
        var byEmail: [String: [Contact]] = [:]
        byLocalID.reserveCapacity(newValue.count)
        // byGuessWhoID intentionally omits reserveCapacity: it holds only
        // RECONCILED contacts (a subset of newValue), so newValue.count over-
        // reserves. byEmail likewise omits it: its key count is the number of
        // DISTINCT email addresses across the book, not the contact count.
        for contact in newValue {
            byLocalID[contact.localID] = contact
            // Pointer entry for RECONCILED contacts only — guessWhoID → localID
            // (canonical lowercase off `ContactID`). Last-writer-wins on a
            // duplicate guessWhoID: if two cached contacts momentarily share one,
            // the later in the array overwrites the pointer. This happens ONLY
            // inside the transient, un-collapsed duplicate-guessWhoID window that
            // reconciliation owns and resolves onto one canonical id; consistent
            // resolution there is what the list VCs' `effectiveID` dedup guard
            // relies on to render one stable row. The rebuild-from-scratch also
            // drops stale pointers automatically (delete, Case-D retire, etc. —
            // no targeted eviction).
            if let gw = ContactID(contact: contact).guessWhoID {
                byGuessWhoID[gw] = contact.localID
            }
            // Index under each DISTINCT email key the contact carries. A contact
            // listing the same address under two labels must still appear only
            // once per key — matching the old `contacts.compactMap` semantics
            // where a per-contact `.contains` yielded one row, not one per label.
            var seenKeys: Set<String> = []
            for email in contact.emailAddresses {
                let key = email.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
                byEmail[key, default: []].append(contact)
            }
        }
        contactsByLocalID = byLocalID
        guessWhoIDToLocalID = byGuessWhoID
        contactsByEmail = byEmail
    }

    private func applyRefresh(localID: String) async {
        var updated = contacts
        await refetch(localID: localID, into: &updated)
        setContacts(updated)
    }

    /// Re-reads ONE Contacts record and applies the result to `working` WITHOUT
    /// committing (no `setContacts`). Splitting fetch from commit lets the batch
    /// `apply(_:)` path apply many changes to one local copy and rebuild the
    /// indexes exactly once. A successful fetch replaces/inserts the fresh record
    /// (or removes it when the store reports it gone); a thrown re-read leaves the
    /// prior cached projection in place — the error is isolated to this one
    /// `localID`, never aborting a batch or leaving indexes half-built.
    private func refetch(localID: String, into working: inout [Contact]) async {
        do {
            let fresh = try await contactsStore.fetch(localID: localID)
            if let fresh {
                if let index = working.firstIndex(where: { $0.localID == localID }) {
                    working[index] = fresh
                } else {
                    working.append(fresh)
                }
            } else {
                working.removeAll { $0.localID == localID }
            }
            lastError = nil
        } catch {
            // A failed individual re-read cannot establish whether the record
            // changed or disappeared, so retain the prior cached projection.
            lastError = "Contact fetch failed: \(error.localizedDescription)"
        }
    }

    @objc
    private nonisolated func contactsDidChange(_ note: Notification) {
        let changeSet = note.userInfo?[GuessWhoContactsDidChangeKey.changeSet] as? ContactChangeSet
        let requiresFullReload = note.userInfo?[GuessWhoContactsDidChangeKey.requiresFullReload] as? Bool ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if requiresFullReload {
                await self.reload()
            } else if let changeSet {
                await self.apply(changeSet)
            }
        }
    }

    /// `@objc` trampoline for `.guessWhoSidecarsDidChange` (posted by
    /// `SidecarFileWatcher`). `nonisolated` per the selector-delivery
    /// convention; hops to the main actor and debounces there.
    @objc
    private nonisolated func sidecarsDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            self?.scheduleSidecarRefresh()
        }
    }

    /// The pending debounced sidecar refresh, if any. Replaced (and the prior
    /// one cancelled) on every notification so only the trailing edge fires —
    /// the same shape as the app's `EventsRepository` reload debounce.
    private var pendingSidecarRefresh: Task<Void, Never>?
    private static let sidecarRefreshDebounce: Duration = .milliseconds(300)

    private func scheduleSidecarRefresh() {
        pendingSidecarRefresh?.cancel()
        pendingSidecarRefresh = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.sidecarRefreshDebounce)
            } catch {
                return   // superseded by a newer notification
            }
            await self?.refreshFromSidecarChange()
        }
    }

    /// Sidecar files changed on disk; Contacts.app records are untouched by
    /// definition. So: NO `fetchAll` — refresh only the sidecar-derived
    /// projection (the bulk timestamp cache that drives time-ordered sorts
    /// and bucket sections) and post a presentation-only reload
    /// (`contactDataChanged: false`, so the app's decoded-photo cache
    /// survives). READ-ONLY over sidecars — this path must never write, or a
    /// watcher post would re-trigger itself in a loop.
    private func refreshFromSidecarChange() async {
        await refreshTimestampCache()
        await refreshLinkedContactIDs()
        await refreshLinkCounts()
        postDidReload(contactDataChanged: false)
    }

    private func apply(_ changeSet: ContactChangeSet) async {
        guard !changeSet.changes.isEmpty else { return }
        // Coalesce the whole delta into ONE index rebuild: apply every change to
        // a single local copy (re-fetching `.updated` records as we go, in
        // history order — a delete then re-add of the same localID must settle as
        // present), then commit once — one rebuild per BATCH, not per change.
        var updated = contacts
        for change in changeSet.changes {
            switch change {
            case .updated(let localID):
                await refetch(localID: localID, into: &updated)
            case .deleted(let localID):
                updated.removeAll { $0.localID == localID }
            }
        }
        setContacts(updated)
        postDidReload()
    }

    // MARK: - Sort & section (parameterized by `sortOrder`)

    /// Filters by `predicate` + search query, then sorts by the CURRENT
    /// `sortOrder` (see `sorted(_:)` for the ordering rules).
    private func filtered(matching query: String, where predicate: (Contact) -> Bool) -> [Contact] {
        let matched = contacts.filter(predicate).filter { $0.matches(searchQuery: query) }
        return sorted(matched)
    }

    /// Sorts an arbitrary contact set by the CURRENT `sortOrder`. Name orders
    /// sort alphabetically (stable `lastNameSortKey` → `displayName` tie-break);
    /// time orders sort by the relevant contact timestamp DESC (most recent
    /// first), a nil timestamp treated as `distantPast` so it lands at the END,
    /// with the same name tie-break among equal timestamps. Shared by
    /// `filtered(matching:where:)` (People / Organizations) and
    /// `sectionedIDs(forMembers:)` (group members) so every person list orders
    /// identically.
    private func sorted(_ matched: [Contact]) -> [Contact] {
        switch sortOrder {
        case .lastFirst:
            return matched.sorted { lhs, rhs in
                nameOrdered(lhs, rhs, primaryKey: \.lastNameSortKey)
            }
        case .firstLast:
            return matched.sorted { lhs, rhs in
                nameOrdered(lhs, rhs, primaryKey: \.firstNameSortKey)
            }
        case .lastModified, .lastInteracted, .lastViewed:
            let kind = sortOrder.timestampKind ?? .modified
            return matched.sorted { lhs, rhs in
                let lt = timestamp(kind, for: lhs) ?? .distantPast
                let rt = timestamp(kind, for: rhs) ?? .distantPast
                if lt != rt { return lt > rt }   // DESC: most recent first
                // Stable tie-break for equal (incl. both-nil) timestamps.
                return nameOrdered(lhs, rhs, primaryKey: \.lastNameSortKey)
            }
        }
    }

    /// Shared alphabetical comparator: compare `primaryKey` case-insensitively,
    /// breaking ties on `displayName`. Returns true when `lhs` sorts before `rhs`.
    private func nameOrdered(_ lhs: Contact, _ rhs: Contact, primaryKey: KeyPath<Contact, String>) -> Bool {
        let primary = lhs[keyPath: primaryKey].localizedCaseInsensitiveCompare(rhs[keyPath: primaryKey])
        if primary != .orderedSame { return primary == .orderedAscending }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    /// The cached timestamp `kind` for `contact`, or nil when the contact is
    /// unreconciled (no GuessWho UUID → no cache entry) or has never been
    /// stamped for that kind.
    private func timestamp(_ kind: ContactTimestampKind, for contact: Contact) -> Date? {
        guard let gw = ContactID(contact: contact).guessWhoID,
              let ts = contactTimestampsByID[gw] else { return nil }
        switch kind {
        case .modified:    return ts.lastModified
        case .interacted:  return ts.lastInteracted
        case .viewed:      return ts.lastViewed
        }
    }

    /// Sections an already-sorted contact list per the CURRENT `sortOrder`:
    /// name orders → A–Z letter sections (first-name leading letter for
    /// `.firstLast`, last-name for `.lastFirst`); time orders → relative-time
    /// buckets. `now` is injectable so time-bucket tests are deterministic; the
    /// public projections call it with `Date()`.
    private func sectioned(_ contacts: [Contact], now: Date = Date()) -> [(String, [Contact])] {
        switch sortOrder {
        case .firstLast:
            return lettered(contacts, by: \.firstNameSectionLetter)
        case .lastFirst:
            return lettered(contacts, by: \.sectionLetter)
        case .lastModified, .lastInteracted, .lastViewed:
            return timeBucketed(contacts, by: sortOrder.timestampKind ?? .modified, now: now)
        }
    }

    /// Groups by an A–Z section-letter key, sorting "#" last. Preserves the
    /// within-section order of the input list (already sorted by `filtered`).
    private func lettered(_ contacts: [Contact], by letter: KeyPath<Contact, String>) -> [(String, [Contact])] {
        Dictionary(grouping: contacts, by: { $0[keyPath: letter] }).map { ($0.key, $0.value) }.sorted {
            switch ($0.0, $1.0) {
            case ("#", _): return false
            case (_, "#"): return true
            default: return $0.0 < $1.0
            }
        }
    }

    // The fixed relative-time bucket titles, in display order. User-facing
    // (these ARE shown), so plain language — no internal vocabulary.
    static let todayBucket = "Today"
    static let thisWeekBucket = "This Week"
    static let thisMonthBucket = "This Month"
    static let earlierBucket = "Earlier"
    static let timeBucketOrder = [todayBucket, thisWeekBucket, thisMonthBucket, earlierBucket]

    /// Buckets contacts by their `kind` timestamp relative to `now`, returning
    /// only the NON-EMPTY buckets in the fixed `timeBucketOrder`. A contact with
    /// no timestamp (unreconciled or never stamped for this kind) buckets as
    /// "Earlier". Within each bucket the input order (timestamp DESC from
    /// `filtered`) is preserved.
    private func timeBucketed(_ contacts: [Contact], by kind: ContactTimestampKind, now: Date) -> [(String, [Contact])] {
        let calendar = Calendar.current
        var buckets: [String: [Contact]] = [:]
        for contact in contacts {
            let title = Self.bucketTitle(for: timestamp(kind, for: contact), now: now, calendar: calendar)
            buckets[title, default: []].append(contact)
        }
        return Self.timeBucketOrder.compactMap { title in
            guard let rows = buckets[title], !rows.isEmpty else { return nil }
            return (title, rows)
        }
    }

    /// Classifies a single timestamp into one of the four relative-time buckets.
    /// nil → "Earlier"; same calendar day as `now` → "Today"; same week-of-year
    /// + year → "This Week"; same month + year → "This Month"; otherwise
    /// "Earlier". (A timestamp earlier this week but on a prior day lands in
    /// "This Week", and one earlier this month in "This Month".)
    static func bucketTitle(for date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return earlierBucket }
        if calendar.isDate(date, inSameDayAs: now) { return todayBucket }
        let dateParts = calendar.dateComponents([.weekOfYear, .month, .year, .yearForWeekOfYear], from: date)
        let nowParts = calendar.dateComponents([.weekOfYear, .month, .year, .yearForWeekOfYear], from: now)
        if dateParts.weekOfYear == nowParts.weekOfYear,
           dateParts.yearForWeekOfYear == nowParts.yearForWeekOfYear {
            return thisWeekBucket
        }
        if dateParts.month == nowParts.month, dateParts.year == nowParts.year {
            return thisMonthBucket
        }
        return earlierBucket
    }

    /// Sections the contacts exactly like `sectioned(_:)`, then maps each row to
    /// its `ContactID`. EVERY row is kept — `ContactID(contact:)` never fails, so
    /// a contact with no GuessWho URL still vends a `localID`-identified row and
    /// no section drops to empty. Section order and within-section sort are
    /// inherited from the passed `Contact` list (already sorted by
    /// `filtered(matching:where:)`). For time orders the section titles are the
    /// relative-time bucket names, not A–Z letters — the app hides the A–Z index
    /// when `sortOrder.isTimeOrder`.
    private func sectionedIDs(_ contacts: [Contact]) -> [(String, [ContactID])] {
        sectioned(contacts).map { letter, rows in
            (letter, rows.map { ContactID(contact: $0) })
        }
    }

    /// Sorts and sections an ARBITRARY contact set (e.g. one group's members) by
    /// the current `sortOrder`, returning the same `[(title, [ContactID])]` shape
    /// `peopleSectionIDs` does — A–Z letter sections for name orders, relative-
    /// time buckets for time orders. The single entry point any person list that
    /// ISN'T the People / Organizations projection should use, so the global sort
    /// applies everywhere identically. Same title contract: the app hides the A–Z
    /// index when `sortOrder.isTimeOrder`.
    public func sectionedIDs(forMembers members: [Contact]) -> [(String, [ContactID])] {
        sectionedIDs(sorted(members))
    }

}

extension ContactSortOrder {
    /// The timestamp cell a time order reads, or nil for the two name orders.
    var timestampKind: ContactTimestampKind? {
        switch self {
        case .firstLast, .lastFirst: return nil
        case .lastModified:          return .modified
        case .lastInteracted:        return .interacted
        case .lastViewed:            return .viewed
        }
    }
}

private extension String {
    /// Whitespace/newline-trimmed copy. File-private convenience for the
    /// LinkedIn-apply merge logic above.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
