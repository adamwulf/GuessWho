import Foundation
import Observation

public extension Notification.Name {
    /// Posted after a `ContactsRepository` cache mutation completes.
    /// Consumers that do not use Observation (for example UIKit diffable data
    /// sources) can observe this notification and apply one new snapshot.
    static let contactsRepositoryDidReload = Notification.Name("ContactsRepositoryDidReload")
}

/// Package-owned in-memory read repository for Contacts.
///
/// The repository is deliberately a read-model cache, not a second source of
/// truth: Contacts remains authoritative. It owns the full reload and
/// incremental-change mechanics so all UI clients observe one coherent view
/// of the address book. It currently also preserves the app's established list
/// query behavior as a transitional compatibility API.
@MainActor
@Observable
public final class ContactsRepository: NSObject {
    private let contactsStore: ContactStoreProtocol

    // The sidecar write engine and the standalone favorites store. BOTH are
    // Optional and nil in the `.unavailable` storage state (no writable
    // sidecar root) — exactly mirroring `SyncService.sync` / `.favoritesStore`.
    // They are wired in here (Stage 6, Step 0) so the repository can reconcile
    // and write a sidecar itself; pre-Stage-6 it held ONLY `contactsStore` and
    // could not. Both are reference-type classes; holding them on this
    // `@MainActor`-isolated repository is what keeps access race-free —
    // `GuessWhoSync` is additionally `@unchecked Sendable` so the stored
    // reference crosses no isolation boundary diagnostic. New methods that
    // depend on either MUST degrade when nil: reads return empty/false, writes
    // throw `SidecarUnavailableError`.
    private let sync: GuessWhoSync?
    private let favorites: FavoritesStore?

    /// The center this repository observes `.guessWhoContactsDidChange` on AND
    /// the one a write-side refresh would notify. Defaults to `.default` so
    /// production wiring is unchanged: the live `ContactChangeWatcher` posts on
    /// `.default`, so a real external contact change still refreshes this repo.
    ///
    /// It is INJECTABLE solely for test isolation. The watcher posts the change
    /// notification with `object: self`, but the repository is constructed
    /// separately from (and holds no reference to) its watcher, so it must
    /// observe with `object: nil` to hear that process-wide "contacts changed"
    /// signal. In production that is correct — there is exactly one repository,
    /// so `object: nil` is harmless. In tests, though, many repositories live at
    /// once on the shared `.default` center; a single `object: nil` observer on
    /// each means ONE test's post of `.guessWhoContactsDidChange` fires EVERY
    /// live repository's `contactsDidChange`, so a parallel test's repo applies a
    /// change set for localIDs it never owned and its assertions corrupt. Giving
    /// each test repository a fresh `NotificationCenter()` confines its observer
    /// to posts made on that same center — the production refresh behavior is
    /// preserved (still `.default`), and parallel `swift test` becomes
    /// deterministic. (Found in the 6d review: `swift test` PARALLEL flaked,
    /// `--no-parallel` always passed.)
    private let notificationCenter: NotificationCenter

    public private(set) var contacts: [Contact] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public var peopleSearch = ""
    public var organizationsSearch = ""

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
    // indexes wholesale, so the array and indexes cannot drift. A wholesale
    // rebuild (rather than an in-place patch) is what makes the reconciliation
    // transition — a contact gaining a `guessWhoID` — re-key automatically: the
    // new array yields a fresh `guessWhoIDToLocalID` pointer (and drops any
    // stale one) while the contact's `localID` slot is unchanged.

    /// Keyed on `localID` (Apple's `CNContact.identifier`). One entry per
    /// contact; backs the `contact(localID:)` Contacts-boundary accessor AND is
    /// the SOLE `Contact` cache — every other identity lookup chases a pointer
    /// into this map, so there is exactly one `Contact` value per contact and
    /// the copies cannot drift.
    private var contactsByLocalID: [String: Contact] = [:]

    /// Pointer index: canonical (lowercase) `guessWhoID` → that contact's
    /// `localID`. Holds ONLY RECONCILED contacts (those whose
    /// `ContactID(contact:).guessWhoID != nil`); it stores no `Contact` value,
    /// just the `localID` to chase back into `contactsByLocalID`. Backs the
    /// guessWhoID branch of `contact(id:)` and all of `contact(guessWhoID:)`.
    /// `guessWhoID` keys are already canonical-lowercase off `ContactID`, but we
    /// are explicit about it everywhere this map is written/read.
    private var guessWhoIDToLocalID: [String: String] = [:]

    /// Keyed on each lowercased+trimmed email address a contact carries; a
    /// contact appears under EVERY email it has, and one email can map to
    /// MULTIPLE contacts (duplicates are preserved). Backs
    /// `contactIDs(matchingEmail:)`.
    private var contactsByEmail: [String: [Contact]] = [:]

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
        // NotificationCenter can deliver synchronously. Consumers must observe
        // the settled loading state when they apply their post-reload snapshot.
        isLoading = false
        postDidReload()
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
        postDidReload()
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
    /// (canonical identity wins; a stale `localID` can never override a real
    /// UUID match), else by `localID`. Returns `nil` when no cached contact
    /// matches (deleted, or a retired/unknown id) — the "unavailable" contract
    /// the UI renders, never a wrong-contact fallback.
    ///
    /// The `localID` branch is LOAD-BEARING, not a mere fallback: it is exactly
    /// the captured-pre-reconcile-token case — a view holds an immutable
    /// `ContactID` minted at navigation whose `guessWhoID` is still nil, and the
    /// contact then reconciled. `localID` is the one identifier that does NOT
    /// move across the reconcile re-key, so resolution MUST go by `id.localID`
    /// there. Do NOT "simplify" this branch away — it is the reason 6d can
    /// delete `ContactDetailView.resolvedLocalID` (the captured token already
    /// carries the `localID` the view used to thread by hand).
    ///
    /// The Case-D-loser subtlety the old doc raised (a stale `localID` re-
    /// resolving to a merged-away duplicate) is MOOT, but for two reasons, not
    /// one. A RECONCILED token (`guessWhoID` set) whose UUID is still in the book
    /// hits the pointer index and returns the canonical contact — it does not
    /// reach the `localID` branch. A reconciled token whose `guessWhoID` was
    /// REMOVED from the book (deleted, or a Case-D loser whose UUID was retired)
    /// DOES fall through to the `localID` branch — but that is safe because Apple
    /// never reuses a deleted record's `CNContact.identifier` for a different
    /// unified contact, so that token's `localID` slot is empty and we return nil
    /// (the "unavailable" contract), never a wrong contact. Only an UNRECONCILED
    /// token (no `guessWhoID`) reaches the `localID` branch to find a real
    /// contact, where `localID` legitimately IS the only identity.
    public func contact(id: ContactID) -> Contact? {
        if let gw = id.guessWhoID, let lid = guessWhoIDToLocalID[gw] {
            return contactsByLocalID[lid]
        }
        return contactsByLocalID[id.localID]
    }

    /// Lazily loads contact photo bytes for the app-facing `ContactID`.
    ///
    /// Bulk contact reloads only fetch `imageDataAvailable`; the expensive image
    /// bytes stay behind this visible-row/detail-driven path. The app passes an
    /// opaque `ContactID`; the repository resolves the package-scoped Contacts
    /// lookup token internally and chooses thumbnail vs. full-size store access.
    public func contactPhotoData(for id: ContactID, kind: ContactPhotoKind) async throws -> ContactPhoto? {
        guard let contact = contact(id: id), contact.imageDataAvailable else {
            return nil
        }

        do {
            let data: Data?
            switch kind {
            case .thumbnail:
                data = try await contactsStore.loadThumbnailImageData(localID: contact.localID)
            case .fullSize:
                data = try await contactsStore.loadImageData(localID: contact.localID)
            }
            guard let data else { return nil }
            return ContactPhoto(data: data, kind: kind)
        } catch ContactStoreError.contactNotFound(_) {
            return nil
        }
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
        try await contactsStore.save(edited)
        await refreshContact(localID: edited.localID)
    }

    /// Sets (or clears, with `nil`) the contact's photo bytes on its Contacts
    /// record, addressed by the app-facing `ContactID`. Image bytes go through
    /// the store's dedicated photo-write path (not `save`), then the one record
    /// is re-read so its `imageDataAvailable` flag reflects the write. The app
    /// is responsible for invalidating any cached decoded image afterwards.
    /// Returns `false` when the id no longer resolves to a contact.
    ///
    /// PREVIOUS-PHOTO SNAPSHOT: before overwriting an EXISTING photo, the
    /// current bytes are captured into a single-slot "previous photo" so a
    /// replacement is recoverable. This is a general rule on the contact-image
    /// write path — every caller that replaces a photo gets it for free; the
    /// app needs no change. Snapshotting is best-effort and never blocks the
    /// actual photo write: a snapshot failure is recorded in `lastError` only.
    @discardableResult
    public func setContactPhoto(for id: ContactID, imageData: Data?) async throws -> Bool {
        guard let localID = contact(id: id)?.localID else { return false }
        await snapshotCurrentPhotoIfPresent(for: id, localID: localID)
        try await contactsStore.setImageData(localID: localID, imageData: imageData)
        await refreshContact(localID: localID)
        return true
    }

    /// Read-before-write: if the contact currently HAS a photo, snapshot those
    /// bytes into a single-slot `previousPhoto` `.blob` before the caller
    /// overwrites them. No current photo → snapshot nothing. Requires the sync
    /// engine (the snapshot is a sidecar write); when nil, there's nowhere to
    /// store it, so it's silently skipped — the photo write still proceeds.
    ///
    /// Resolving the contact's GuessWho UUID can MINT one for a previously-
    /// unreconciled contact (same resolve-or-mint path the other sidecar writes
    /// use), so the cache is refreshed if that happens.
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
            // `.dat` (orphan sweep is the cross-device backstop).
            _ = try sync.setBlobField(
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

    /// The single-slot field name the previous-photo snapshot lives under. This
    /// is an INTERNAL identifier, NOT a display string: the `.blob` field it
    /// names is excluded from the user-visible custom-fields list by
    /// `fields(for:)` (a `.blob` is infrastructure, not a user-editable field),
    /// so the raw "previousPhoto" token never reaches the UI. A future
    /// "previous photo" feature would render its own plain-language label and
    /// read the bytes via `GuessWhoSync.blobFieldData`, not surface this name.
    /// v1 only guarantees capture.
    static let previousPhotoFieldName = "previousPhoto"

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
    /// - Sidecar fields (about/location) are stored as notes prefixed with
    ///   "LinkedIn …: " so the source is obvious to the user.
    /// - `photo` is accepted in `fields` but not yet applied (the contact-image
    ///   write path is a separate step); it's a no-op here for now.
    ///
    /// Throws if the contact can't be fetched/saved. Returns the refreshed
    /// `Contact` (CNContact fields; sidecar notes are read separately).
    ///
    /// NOTE: adding the about/location notes can MINT a GuessWho ID for a
    /// previously-unreconciled contact. After this call, use the RETURNED
    /// contact's `contactID` for any follow-up sidecar reads — an older
    /// `ContactID` held by the caller may be pre-mint (stale) for note reads.
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
        if fields.contains(.websites) {
            let additions = Self.newValues(
                profile.contactInfo?.websites ?? [],
                notIn: edited.urlAddresses.map(\.value),
                key: Self.urlDedupKey
            )
            // CNContact field — default label (empty -> adapter passes nil).
            edited.urlAddresses += additions.map { LabeledValue(label: "", value: $0) }
        }
        if fields.contains(.linkedInURL),
           let url = (profile.contactInfo?.profileUrl ?? profile.sourceUrl)?.trimmed, !url.isEmpty {
            let slug = LinkedInURL.slug(from: url) ?? ""
            // A LinkedIn social profile is identified by its service ("LinkedIn")
            // — existing ones may store only a username (no urlString), so match
            // on service or a same-slug urlString/username, not urlString alone.
            let existingIndex = edited.socialProfiles.firstIndex { lp in
                let p = lp.value
                if p.service.caseInsensitiveCompare("LinkedIn") == .orderedSame { return true }
                if !p.urlString.isEmpty, LinkedInURL.sameProfile(p.urlString, url) { return true }
                if !p.username.isEmpty, !slug.isEmpty, p.username.caseInsensitiveCompare(slug) == .orderedSame { return true }
                return false
            }
            // Contacts' LinkedIn social-profile field expects the USERNAME, not a
            // URL (it derives the URL from the username; a stored URL shows blank
            // in the normal card view). So store just the slug.
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

        // Sidecar key/value fields (about/location aren't CNContact fields). Use
        // UPSERT by name (not append-only notes) so re-importing the same profile
        // updates the value instead of duplicating it. Field names are prefixed
        // "LinkedIn " so the source is obvious.
        if fields.contains(.about), let about = profile.about?.trimmed, !about.isEmpty {
            // About is multi-line prose.
            _ = try await upsertField(for: id, field: "LinkedIn About", value: about, type: .multilineNote)
        }
        if fields.contains(.location), let loc = profile.location?.trimmed, !loc.isEmpty {
            // Location is a single line.
            _ = try await upsertField(for: id, field: "LinkedIn Location", value: loc, type: .note)
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

    /// The reconciled GuessWho UUID carried by `contact`, or `nil` when the
    /// contact has no valid `guesswho://` URL yet (un-reconciled). This is the
    /// EFFECTIVE GuessWho identity — `ContactID(contact:).guessWhoID` — NOT the
    /// `localID` fallback: a contact with no GuessWho URL has no sidecar data to
    /// key on, so callers binding favorites/notes/links/tags must get `nil` (and
    /// stand down) rather than a transient `localID`.
    ///
    /// A PURE function of the passed contact — no cache read — so it reads the
    /// UUID off the live record the caller already holds, with no cache-miss
    /// window. Identity comes from `SidecarKey` exactly as `Contact.contactID`
    /// and `contact(id:)` resolve it. The sanctioned way for the app to read an OPENED
    /// contact's own GuessWho UUID without reaching into `ContactID.guessWhoID`
    /// (which is `package`): the detail view holds the loaded `Contact` and binds
    /// its sidecar stores on this. Semantics match the former
    /// `SyncService.guessWhoUUID(in:)` byte-for-byte (it walked the same
    /// `urlAddresses` via the same `SidecarKey` parser).
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
    /// `guessWhoIDToLocalID[uuid]` → `contactsByLocalID[localID]`. NO confirm-
    /// guard — `guessWhoIDToLocalID` is keyed ONLY on real `guessWhoID`s (it
    /// excludes unreconciled contacts entirely), so it can never return a
    /// `localID`-coincidence; the pure guessWhoID keyspace IS the guarantee the
    /// old confirm-guard provided. Input is lowercased to match the canonical
    /// lowercase keys (`SidecarKey` / `Favorite` already lowercase their ids —
    /// defensive). Returns `nil` for an unknown/retired UUID, or for a string
    /// that is only some contact's `localID` — the "unavailable" contract, never
    /// a wrong-contact fallback.
    ///
    /// STAYS PUBLIC: favorites and links sync between devices and so persist the
    /// stable GuessWho UUID (not a `ContactID`, which carries the transient
    /// `localID` and is not `Codable` for that reason). The app legitimately
    /// reads bare guessWhoID strings off disk and resolves them here — the
    /// bridge that lets it resolve a link endpoint / favorite without an app-side
    /// `uuid → Contact` map.
    package func contact(guessWhoID: String) -> Contact? {
        guard let lid = guessWhoIDToLocalID[guessWhoID.lowercased()] else { return nil }
        return contactsByLocalID[lid]
    }

    // MARK: - Reconcile-on-write (resolve-or-mint)
    //
    // The INTERNAL plumbing every WRITE entry point (notes/links/favorite —
    // landing in sub-phase 6b) routes through to obtain the GuessWho UUID it
    // writes the sidecar at. Reconcile is a package-INTERNAL side effect of a
    // write: the app never triggers, sees, or names it.

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
    ///   stamped a URL without populating `assignedUUID` (mirrors the app's
    ///   former `SyncService.reconcileIfNeeded`).
    ///
    /// DEGRADES when the engine is nil (the `.unavailable` storage state): a
    /// write to an unreconciled contact has nowhere to mint, so it THROWS
    /// `SidecarUnavailableError` rather than silently no-op — matching the
    /// existing app write behavior the caller expects.
    ///
    /// CONCURRENCY — accepts a rare double-mint by design; does NOT serialize.
    /// Two truly-concurrent writes to the SAME never-reconciled `ContactID`
    /// could each mint before the other's write lands, because resolve-or-mint
    /// must `await` the reconcile (which `await`s `contacts.fetch`) and the
    /// engine's per-key locks (`PerKeyLockTable`) are SYNCHRONOUS `NSLock`s that
    /// CANNOT be held across that `await`. This is accepted as a practical
    /// non-event (it needs a never-reconciled contact AND two simultaneous
    /// writes from different surfaces — effectively only Catalyst multi-window);
    /// no async-serialization machinery is added here. See the Stage 6
    /// "CONCURRENCY (decision: ACCEPT double-mint...)" paragraph in
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
        // the on-disk contact's URL without populating that field (e.g. a stale
        // in-memory snapshot of a contact that already carried a valid URL).
        // Re-fetch the single record post-write so we read the freshly written
        // UUID, then derive it via the same `SidecarKey` parser `ContactID` uses.
        if let fresh = try? await contactsStore.fetch(localID: id.localID),
           let stamped = ContactID(contact: fresh).guessWhoID {
            return stamped
        }
        throw ReconcileAssignmentFailedError()
    }

    // MARK: - ContactID-keyed contact API (notes / links / favorites)
    //
    // Sub-phase 6b — the PUBLIC contact-sidecar surface the app speaks, keyed
    // exclusively on `ContactID`. Plain verbs (no "sidecar" in any name): the
    // app never constructs a `SidecarKey` or sees the word — the repository
    // translates a `ContactID` to `SidecarKey(kind: .contact, id: guessWhoID)`
    // internally and calls the engine. Semantics mirror today's app
    // `SyncService` contact-sidecar methods byte-for-byte (so 6d can repoint the
    // app onto these with no behavior change).
    //
    // READS are SYNCHRONOUS: `id.guessWhoID` is already on the value, so no
    // reconcile and no `await`. An UNRECONCILED contact (`id.guessWhoID == nil`)
    // has no sidecar yet, so reads return empty/false and MINT NOTHING — reads
    // never reconcile (Design step 3).
    //
    // WRITES are `async`: they resolve-or-mint the GuessWho UUID first (6a's
    // `resolveOrMintGuessWhoID`, which `await`s reconcile), then call the engine,
    // then — if the resolve MINTED (decision B) — refresh the affected contact
    // in the cache so the app needs no post-write reload. When the engine (or,
    // for favorites, the favorites store) is nil — the `.unavailable` storage
    // state — writes THROW `SidecarUnavailableError` rather than silently no-op,
    // matching `SyncService`'s throw behavior.

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

    /// Live contact↔contact links on the contact identified by `id`. Excludes
    /// soft-deleted links and links whose FAR endpoint is not a contact (those
    /// are event links — see `eventLinks(for:)`). Returns `[]` when the contact
    /// is unreconciled or the engine is unavailable. Mirrors
    /// `SyncService.contactLinks(forContactUUID:)`.
    public func links(for id: ContactID) -> [Link] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        do {
            return try sync.links(at: endpoint).filter { link in
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
    /// deferred event-identity migration — events are out of scope for Stage 6.)
    public func eventLinks(for id: ContactID) -> [Link] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        do {
            return try sync.links(at: endpoint).filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .event
            }
        } catch {
            lastError = "event links read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// The bare EVENT-endpoint UUIDs of every live contact↔event link on the
    /// contact identified by `id`. The package resolves the far (event) endpoint
    /// internally so the app never constructs a `.contact` `SidecarKey` to walk
    /// a link — it hands its `ContactID` and gets back the event UUIDs it then
    /// asks the event surface to refresh (an out-of-scope event-cache concern
    /// that still lives on `SyncService`). Returns `[]` when the contact is
    /// unreconciled or the engine is unavailable. (The EVENT endpoint stays a
    /// bare UUID until the deferred event-identity migration.)
    public func linkedEventUUIDs(for id: ContactID) -> [String] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
        do {
            return try sync.links(at: endpoint).compactMap { link in
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

    /// Project persisted favorites into app-facing rows without exposing contact
    /// favorite UUIDs. Contact favorites resolve through this repository's
    /// GuessWhoID index; event favorites use the supplied resolver until the
    /// deferred EventID migration moves event identity behind the package too.
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
    public func addNote(for id: ContactID, body: String) async throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let noteID = try sync.addNote(at: SidecarKey(kind: .contact, id: guessWhoID), body: body)
        await refreshCacheIfMinted(minted, localID: id.localID)
        return noteID
    }

    /// All live (non-deleted) USER-VISIBLE sidecar fields on the contact, by
    /// `ContactID`. Returns empty for an unreconciled id (no mint on read).
    ///
    /// `.blob` fields are EXCLUDED: they are internal infrastructure (e.g. the
    /// `previousPhoto` snapshot), not user-editable custom fields. Surfacing one
    /// would render a phantom row (e.g. literally "previousPhoto") in the
    /// contact's custom-fields UI — a product-principle violation. The contact
    /// custom-fields surface is text/date/checkbox only; blobs are read through
    /// their own typed accessors (`GuessWhoSync.blobFieldData`).
    public func fields(for id: ContactID) -> [SidecarField] {
        guard let sync, let guessWhoID = id.guessWhoID else { return [] }
        let all = (try? sync.fields(at: SidecarKey(kind: .contact, id: guessWhoID))) ?? []
        return all.filter { $0.deletedAt == nil && $0.type != .blob }
    }

    /// Upsert a named free-text sidecar field on the contact, by `field` name:
    ///  - no existing field → create it with `type`;
    ///  - existing field, SAME type → update its value in place;
    ///  - existing field, DIFFERENT type → replace it (delete + recreate) so the
    ///    type can change. The per-cell type is write-once, but replacing the
    ///    whole field programmatically is allowed (the UI keeps the type fixed;
    ///    this lets an import upgrade e.g. a single-line `.note` to a
    ///    `.multilineNote`).
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
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        let key = SidecarKey(kind: .contact, id: guessWhoID)

        let existing = ((try? sync.fields(at: key)) ?? [])
            .first { $0.deletedAt == nil && $0.field == field }

        let fieldID: UUID
        if let existing, existing.type == type {
            // Same type — update in place.
            try sync.setField(at: key, id: existing.id, field: field, value: .string(value))
            fieldID = existing.id
        } else {
            // Different type (or new) — replace: soft-delete the old, create new.
            if let existing {
                try sync.deleteField(at: key, id: existing.id)
            }
            fieldID = try sync.addField(at: key, field: field, type: type, value: .string(value))
        }
        await refreshCacheIfMinted(minted, localID: id.localID)
        return fieldID
    }

    /// Edit an existing sidecar field's value (by field id) on the contact.
    /// `id` is the CONTACT, `fieldID` the field. Silent no-op if the field is
    /// gone. Throws `SidecarUnavailableError` if no engine.
    public func editField(for id: ContactID, id fieldID: UUID, value: String) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        // setField needs the field's current name (it's preserved); read it.
        let key = SidecarKey(kind: .contact, id: guessWhoID)
        let name = ((try? sync.fields(at: key)) ?? []).first { $0.id == fieldID }?.field
        if let name {
            try sync.setField(at: key, id: fieldID, field: name, value: .string(value))
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
    /// `id`s are disambiguated: `id` is the CONTACT, `noteID` is the note. (No
    /// mint can happen via an edit in practice — you can only edit a note that
    /// exists, which means the contact is already reconciled — but resolve-or-
    /// mint is still routed for consistency with the other writes, and the cache
    /// is refreshed in the impossible-mint case for safety.) Throws when the
    /// engine is unavailable. Mirrors `SyncService.editNote(id:newBody:forContactUUID:)`.
    public func editNote(for id: ContactID, id noteID: UUID, newBody: String) async throws {
        guard let sync else { throw SidecarUnavailableError() }
        let minted = id.guessWhoID == nil
        let guessWhoID = try await resolveOrMintGuessWhoID(for: id)
        try sync.editNote(at: SidecarKey(kind: .contact, id: guessWhoID), id: noteID, newBody: newBody)
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

    /// Toggle the favorite state of the contact identified by `id`, returning
    /// the NEW state (`true` if just favorited, `false` if unfavorited).
    /// Resolves-or-mints the GuessWho UUID first (favoriting a never-touched
    /// contact reconciles + mints, transparent to the caller — the deliberate
    /// UX change that lets the favorite gate drop in 6d), then toggles the
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
    // Notes/links/favorite writes do NOT alter the cached `Contact` record —
    // they live in the sidecar / favorites file, not on the `CNContact`. So the
    // ONLY write that changes the cached Contact is the FIRST write to an
    // unreconciled contact, where resolve-or-mint stamped a fresh `guesswho://`
    // URL onto its `urlAddresses` (changing its `guessWhoID` and thus its
    // effective identity). In that case — and ONLY that case — re-read the one
    // record so the cache reflects the new identity and the app needs no
    // post-write reload. `refreshContact(localID:)` re-fetches the single record
    // and rebuilds the indexes, automatically re-keying it under the new
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
        // (the funnel appends per contact as it walks the array), so this
        // preserves the previous `contacts.compactMap` ordering and returns
        // ALL matches.
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
        filtered(matching: peopleSearch, where: { $0.contactType == .person })
    }

    public var organizations: [Contact] {
        filtered(matching: organizationsSearch, where: { $0.contactType == .organization })
    }

    public var peopleSections: [(String, [Contact])] { sectioned(people) }
    public var organizationsSections: [(String, [Contact])] { sectioned(organizations) }

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

    private func postDidReload() {
        // Routed through the injected center (defaults to `.default`, so the
        // app's list controllers still observe it) — the outbound reload and the
        // inbound change observer share one center so a test on a fresh center
        // sees its own repository's reload and nothing else's. The `object: self`
        // scope already keeps this signal per-repository; the injected center is
        // what isolates the inbound `object: nil` change observer (see init).
        notificationCenter.post(name: .contactsRepositoryDidReload, object: self)
    }

    /// The SINGLE funnel for every `contacts` mutation. Reassigns the array
    /// (preserving `@Observable` tracking of the stored property) and rebuilds
    /// all three point-lookup indexes from the new array so they can never
    /// drift from it. Incremental sites (refresh / remove / delta-apply) mutate
    /// a local copy and call this once; a wholesale index rebuild at v1
    /// address-book scale is cheap and eliminates a whole class of patch-drift
    /// bugs — including the reconciliation re-key, which is automatic here
    /// because the new array yields the new effective-id key and never
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
            // (canonical lowercase guessWhoID off `ContactID`). Last-writer-wins
            // on a duplicate guessWhoID: if two cached contacts momentarily share
            // one, the later one in the array overwrites the pointer. This is the
            // pointer analogue of today's last-writer-wins on the old fused index,
            // and it occurs ONLY inside a transient, un-collapsed duplicate-
            // guessWhoID window that reconciliation owns and resolves onto one
            // canonical id. Consistent resolution there is what the list VCs'
            // `effectiveID` dedup guard relies on to render one stable row.
            // Rebuilding from scratch on every funnel call also drops a stale
            // guessWhoID/localID pointer automatically (delete, Case-D retire,
            // etc. are all handled by rebuild-from-scratch, no targeted eviction).
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
    /// committing (no `setContacts`). Splitting the fetch from the commit lets
    /// the batch `apply(_:)` path apply many changes to one local copy and
    /// rebuild the indexes exactly once. A successful fetch replaces/inserts the
    /// fresh record (or removes it when the store reports it gone); a thrown
    /// re-read leaves the prior cached projection in place — error is isolated to
    /// this one `localID`, never aborting a batch or leaving indexes half-built.
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

    private func apply(_ changeSet: ContactChangeSet) async {
        guard !changeSet.changes.isEmpty else { return }
        // Coalesce the whole delta into ONE index rebuild: apply every change to
        // a single local copy (re-fetching `.updated` records from the store as
        // we go, in history order — a delete then re-add of the same localID must
        // settle as present), then commit once. A delta of M changes costs one
        // rebuild per BATCH, not M.
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

    private func filtered(matching query: String, where predicate: (Contact) -> Bool) -> [Contact] {
        contacts.filter(predicate).filter { $0.matches(searchQuery: query) }.sorted {
            let primary = $0.lastNameSortKey.localizedCaseInsensitiveCompare($1.lastNameSortKey)
            if primary != .orderedSame { return primary == .orderedAscending }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func sectioned(_ contacts: [Contact]) -> [(String, [Contact])] {
        Dictionary(grouping: contacts, by: \.sectionLetter).map { ($0.key, $0.value) }.sorted {
            switch ($0.0, $1.0) {
            case ("#", _): return false
            case (_, "#"): return true
            default: return $0.0 < $1.0
            }
        }
    }

    /// Sections the contacts exactly like `sectioned(_:)`, then maps each row to
    /// its `ContactID`. EVERY row is kept — `ContactID(contact:)` never fails, so
    /// a contact with no GuessWho URL still vends a `localID`-identified row and
    /// no section can become empty by dropping. Section order and the
    /// within-section sort are inherited from the `Contact` list passed in
    /// (already sorted by `filtered(matching:where:)`).
    private func sectionedIDs(_ contacts: [Contact]) -> [(String, [ContactID])] {
        sectioned(contacts).map { letter, rows in
            (letter, rows.map { ContactID(contact: $0) })
        }
    }

}

private extension String {
    /// Whitespace/newline-trimmed copy. File-private convenience for the
    /// LinkedIn-apply merge logic above.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
