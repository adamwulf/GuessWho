#if canImport(Contacts)
// CNContactStore is documented thread-safe ("Because CNContactStore
// fetch methods perform I/O, it's recommended that you avoid using
// the main thread to execute fetches") but not formally Sendable in
// the Contacts overlay. `@preconcurrency` suppresses the Sendable
// warnings on the cross-queue captures below; the runtime contract
// is still met because the actor serializes all access through one
// dedicated `.userInitiated` queue.
@preconcurrency import Contacts
import Foundation
import Logging
// Bridges the Swift-unavailable enumeratorForChangeHistoryFetchRequest call.
import GuessWhoSyncObjC

public actor CNContactStoreAdapter: ContactStoreProtocol {
    private let store: CNContactStore

    /// Routes contact-save failure breadcrumbs through swift-log. With the app's
    /// logging backend bootstrapped these land in `<AppGroup>/Logs/app.log` (and
    /// echo to the OS console); under `swift test` (no bootstrap) they fall back
    /// to swift-log's default handler. Developer-facing — internal vocabulary is
    /// fine in the message body. Stable label so the lines are greppable.
    private static let saveLog = Logger(label: "sync.contact-save")

    /// Dedicated serial queue that runs every blocking CNContactStore call,
    /// pinned to `.userInitiated`. The actor's executor can be provisioned at
    /// Background QoS by the Swift concurrency runtime, and
    /// `CNContactStore.enumerateContacts` synchronously XPCs to a daemon at
    /// whatever QoS the actor's thread inherits. Without this queue, calling
    /// `await contactsAdapter.fetchAll()` from a higher-QoS caller (e.g. the
    /// `@MainActor` SyncService) blocks it on a lower-QoS thread — the runtime's
    /// "Hang Risk: priority inversion" warning.
    private let workQueue = DispatchQueue(
        label: "guesswho.contacts-adapter",
        qos: .userInitiated
    )

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    /// Stamped on every `CNSaveRequest` this adapter executes so our own writes
    /// can be excluded from the change-history delta read in `changes(since:)`.
    /// A fixed compile-time constant (the app's bundle id) — it is meaningful
    /// only at write time and is never persisted.
    static let transactionAuthor = "com.milestonemade.guesswho"

    /// Single chokepoint for constructing a write request: every save/delete/
    /// group/membership mutation goes through here so none can forget to tag
    /// the author. An untagged write would surface as a phantom self-edit in
    /// the delta. Internal (not private) so @testable tests can assert the
    /// author tag without executing a request against a real store.
    static func makeSaveRequest() -> CNSaveRequest {
        let request = CNSaveRequest()
        request.transactionAuthor = transactionAuthor
        return request
    }

    // Internal (not private) so @testable tests can assert the fetch-key
    // contract. Debug and Release use the same app id and entitlements, so both
    // fetch `CNContactNoteKey` and map it into `Contact.note`.
    static let keys: [CNKeyDescriptor] = [
        // Identifier
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,

        // Names
        CNContactNamePrefixKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPreviousFamilyNameKey as CNKeyDescriptor,
        CNContactNameSuffixKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneticGivenNameKey as CNKeyDescriptor,
        CNContactPhoneticMiddleNameKey as CNKeyDescriptor,
        CNContactPhoneticFamilyNameKey as CNKeyDescriptor,

        // Work
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneticOrganizationNameKey as CNKeyDescriptor,

        // Notes
        CNContactNoteKey as CNKeyDescriptor,

        // Addresses & channels
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,

        // Dates
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
        CNContactDatesKey as CNKeyDescriptor,

        // Social / IM / relations
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactInstantMessageAddressesKey as CNKeyDescriptor,
        CNContactRelationsKey as CNKeyDescriptor,

        // Image presence flag (bytes loaded on demand)
        CNContactImageDataAvailableKey as CNKeyDescriptor,
    ]

    private static let imageKeys: [CNKeyDescriptor] = [
        CNContactImageDataKey as CNKeyDescriptor,
    ]

    private static let thumbnailKeys: [CNKeyDescriptor] = [
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
    ]

    // MARK: - Authorization

    /// Current contacts authorization. `CNContactStore.authorizationStatus`
    /// is a static system-state read (not per-instance), so this witness is
    /// `nonisolated` — it touches no actor state, so it does no async work and
    /// satisfies the `async` protocol requirement without a suspension point.
    /// `.limited` collapses to `.authorized`.
    public nonisolated func contactsAuthorizationStatus() -> StoreAuthorizationStatus {
        Self.mapAuthorization(CNContactStore.authorizationStatus(for: .contacts))
    }

    /// Prompt for contacts access on this actor's store and return the
    /// resulting `StoreAccessResult`. `requestAccess(for:)` is a no-op once the
    /// user has already decided; a thrown error is surfaced as `.denied` with a
    /// non-nil `failureDescription` (the error's `localizedDescription`) so the
    /// caller can restore its error-state write.
    public func requestContactsAccess() async -> StoreAccessResult {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            do {
                let granted = try await store.requestAccess(for: .contacts)
                return StoreAccessResult(status: granted ? .authorized : .denied)
            } catch {
                return StoreAccessResult(status: .denied, failureDescription: error.localizedDescription)
            }
        case .authorized, .limited:
            return StoreAccessResult(status: .authorized)
        case .denied:
            return StoreAccessResult(status: .denied)
        case .restricted:
            return StoreAccessResult(status: .restricted)
        @unknown default:
            return StoreAccessResult(status: .denied)
        }
    }

    // Internal (not private) so @testable tests can cover the collapse table
    // (notably `.limited` → `.authorized`) without touching system state.
    static func mapAuthorization(_ status: CNAuthorizationStatus) -> StoreAuthorizationStatus {
        switch status {
        case .authorized, .limited: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func fetchAll() async throws -> [Contact] {
        try await runOnWorkQueue { store in
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            var results: [Contact] = []
            try store.enumerateContacts(with: request) { cnContact, _ in
                results.append(Self.toContact(cnContact))
            }
            return results
        }
    }

    public func fetch(localID: String) async throws -> Contact? {
        try await runOnWorkQueue { store in
            do {
                let cnContact = try store.unifiedContact(withIdentifier: localID, keysToFetch: Self.keys)
                return Self.toContact(cnContact)
            } catch let error as CNError where error.code == .recordDoesNotExist {
                return nil
            }
        }
    }

    public func save(_ contact: Contact) async throws {
        try await runOnWorkQueue { store in
            let saveRequest = Self.makeSaveRequest()
            let existing = try? store.unifiedContact(withIdentifier: contact.localID, keysToFetch: Self.keys)
            if let existing, let mutable = existing.mutableCopy() as? CNMutableContact {
                Self.apply(contact, to: mutable)
                saveRequest.update(mutable)
            } else {
                let mutable = CNMutableContact()
                Self.apply(contact, to: mutable)
                saveRequest.add(mutable, toContainerWithIdentifier: nil)
            }
            do {
                try store.execute(saveRequest)
            } catch {
                // DEBUG BREADCRUMB (developer surface, never user-facing): a
                // CNSaveRequest.execute() rejection arrives as a terse "Cocoa
                // error <code>" with the actionable detail buried in userInfo /
                // NSUnderlyingError. Log the full chain so the failing
                // account/property shows in the device log, then re-throw the
                // ORIGINAL error so categorization (and the user's alert) is
                // unchanged. Most common cause: a contact unified across
                // accounts where one backing card lives in a read-only source
                // (Exchange/Google directory, social card); the write fans out
                // to that card and is rejected.
                Self.logSaveFailure(error, contactLocalID: contact.localID)
                throw error
            }
        }
    }

    public func create(_ contact: Contact) async throws -> Contact {
        try await runOnWorkQueue { store in
            let saveRequest = Self.makeSaveRequest()
            let mutable = CNMutableContact()
            Self.apply(contact, to: mutable)
            saveRequest.add(mutable, toContainerWithIdentifier: nil)
            do {
                try store.execute(saveRequest)
            } catch {
                Self.logSaveFailure(error, contactLocalID: mutable.identifier)
                throw error
            }
            // A CNMutableContact's identifier is assigned at init and survives
            // the save, so it addresses the record just created. Re-read the
            // UNIFIED card (the package's fetch model) so the returned Contact
            // matches what every later fetch sees.
            let created = try store.unifiedContact(withIdentifier: mutable.identifier, keysToFetch: Self.keys)
            return Self.toContact(created)
        }
    }

    /// Emits the full error chain for a failed contact save through swift-log
    /// (so it lands in `<AppGroup>/Logs/app.log` via FellerBuncher, NOT just the
    /// OS unified log where the detail is `<private>`-redacted). This is a
    /// developer-facing debug breadcrumb and is NOT shown to the user —
    /// `saveErrorCategory` owns the user-facing message.
    ///
    /// Walks `NSUnderlyingError` so the buried `CNError` / per-property detail
    /// (which names the offending account or field — e.g. the keys behind a
    /// 134092 rejection) is captured alongside the top-level "Cocoa error
    /// <code>". One log line per level (top, then `underlying[0]`, `[1]`, …) for
    /// independent grepping. The whole `userInfo` dict is dumped (no allowlist)
    /// since the actionable key is often undocumented; file output escapes the
    /// OS `<private>` redaction, so it lands in full.
    nonisolated static func logSaveFailure(_ error: Error, contactLocalID: String) {
        // Native swift-log metadata form (matches ContactChangeWatcher): this
        // package depends on swift-log directly, NOT GuessWhoLogging, so the
        // positional `[String: CustomStringConvertible]` convenience overload
        // isn't in scope here.
        let ns = error as NSError
        saveLog.error("contact save failed", metadata: [
            "localID": .string(contactLocalID),
            "domain": .string(ns.domain),
            "code": .stringConvertible(ns.code),
            "localizedDescription": .string(ns.localizedDescription),
            "userInfo": .string(String(describing: ns.userInfo)),
        ])
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let u = underlying, depth < 5 {
            saveLog.error("contact save underlying", metadata: [
                "depth": .stringConvertible(depth),
                "domain": .string(u.domain),
                "code": .stringConvertible(u.code),
                "localizedDescription": .string(u.localizedDescription),
                "userInfo": .string(String(describing: u.userInfo)),
            ])
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
    }

    public func delete(localID: String) async throws {
        try await runOnWorkQueue { store in
            let cn: CNContact
            do {
                cn = try store.unifiedContact(
                    withIdentifier: localID,
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                )
            } catch let error as CNError where error.code == .recordDoesNotExist {
                throw ContactStoreError.contactNotFound(localID: localID)
            }
            // mutableCopy() on a CNContact always returns CNMutableContact.
            let mutable = cn.mutableCopy() as! CNMutableContact
            let req = Self.makeSaveRequest()
            req.delete(mutable)
            try store.execute(req)
        }
    }

    public func changes(since token: Data?) async throws -> ContactChangeSet {
        try await runOnWorkQueue { store in
            // nil token ⇒ first run (or cursor loss). The delta from the dawn of
            // history isn't a meaningful "what changed for you" set, and the
            // caller baselines via a full reload regardless — so skip the history
            // fetch entirely (it would materialize the ENTIRE recorded history
            // just to discard it) and hand back the current token plus
            // requiresFullReload. `currentHistoryToken` is a cheap property read,
            // not an enumeration.
            if token == nil {
                let baseline = (store.currentHistoryToken as Data?) ?? Data()
                return ContactChangeSet(
                    changes: [],
                    newToken: baseline,
                    requiresFullReload: true
                )
            }

            let request = CNChangeHistoryFetchRequest()
            // The token is opaque `Data`; pass it straight through. nil here
            // means "from the beginning" per Apple's contract.
            request.startingToken = token
            // Our own writes are tagged with this author (every CNSaveRequest
            // routes through makeSaveRequest), so they never surface in the
            // delta.
            request.excludedTransactionAuthors = [Self.transactionAuthor]
            // Group / membership churn must never enter the contact delta.
            request.includeGroupChanges = false

            // Per TN3149 the enumeration is visitor-driven; token invalidation /
            // first-run / truncation arrives as a DropEverything event in the
            // stream, NOT a thrown error. Genuine I/O / auth failures still throw
            // and propagate. The fetch goes through the ObjC shim because the
            // underlying enumeratorForChangeHistoryFetchRequest call is
            // Swift-unavailable.
            let visitor = ChangeHistoryVisitor()
            var fetchedToken: NSData?
            let events = try Self.runChangeHistoryFetch(store: store, request: request, token: &fetchedToken)
            // Each event dispatches itself to the matching visitor method via
            // `acceptEventVisitor:`, preserving history order.
            for event in events {
                event.accept(visitor)
            }

            // currentHistoryToken can be nil on an empty store; persist Data()
            // in that case so the cursor is still a stable, advanceable value.
            let newToken = (fetchedToken as Data?) ?? Data()
            // First-run (nil token) returned early above, so here a full reload
            // is required only when the history stream dropped everything (token
            // invalidation / truncation) — in which case the partial delta is
            // meaningless and the caller rebuilds from a full reload.
            let requiresFullReload = visitor.droppedEverything
            let changes = requiresFullReload ? [] : visitor.changes
            return ContactChangeSet(
                changes: changes,
                newToken: newToken,
                requiresFullReload: requiresFullReload
            )
        }
    }

    public func loadImageData(localID: String) async throws -> Data? {
        try await runOnWorkQueue { store in
            do {
                let cn = try store.unifiedContact(withIdentifier: localID, keysToFetch: Self.imageKeys)
                return cn.imageData
            } catch let error as CNError where error.code == .recordDoesNotExist {
                throw ContactStoreError.contactNotFound(localID: localID)
            }
        }
    }

    public func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await runOnWorkQueue { store in
            do {
                let cn = try store.unifiedContact(withIdentifier: localID, keysToFetch: Self.thumbnailKeys)
                return cn.thumbnailImageData
            } catch let error as CNError where error.code == .recordDoesNotExist {
                throw ContactStoreError.contactNotFound(localID: localID)
            }
        }
    }

    public func setImageData(localID: String, imageData: Data?) async throws {
        try await runOnWorkQueue { store in
            let cn: CNContact
            do {
                // Fetch with only the image key so the mutableCopy carries just
                // that key: the `update` writes ONLY the photo, leaving every
                // other field untouched (the OS regenerates the thumbnail from
                // the new full-size bytes).
                cn = try store.unifiedContact(withIdentifier: localID, keysToFetch: Self.imageKeys)
            } catch let error as CNError where error.code == .recordDoesNotExist {
                throw ContactStoreError.contactNotFound(localID: localID)
            }
            // mutableCopy() on a CNContact always returns CNMutableContact.
            let mutable = cn.mutableCopy() as! CNMutableContact
            mutable.imageData = imageData
            let request = Self.makeSaveRequest()
            request.update(mutable)
            do {
                try store.execute(request)
            } catch {
                // Same breadcrumb as `save(_:)` above: log the full
                // Cocoa/CNError chain, then re-throw the original error
                // unchanged so the caller's error categorization/alert is
                // unaffected.
                Self.logSaveFailure(error, contactLocalID: localID)
                throw error
            }
        }
    }

    // MARK: - Groups

    public func fetchAllGroups() async throws -> [ContactGroup] {
        try await runOnWorkQueue { store in
            let cnGroups = try store.groups(matching: nil)
            return cnGroups.map { ContactGroup(localID: $0.identifier, name: $0.name) }
        }
    }

    public func fetchGroup(localID: String) async throws -> ContactGroup? {
        try await runOnWorkQueue { store in
            let predicate = CNGroup.predicateForGroups(withIdentifiers: [localID])
            let cnGroups = try store.groups(matching: predicate)
            guard let g = cnGroups.first else { return nil }
            return ContactGroup(localID: g.identifier, name: g.name)
        }
    }

    public func createGroup(name: String) async throws -> ContactGroup {
        try await runOnWorkQueue { store in
            let mutable = CNMutableGroup()
            mutable.name = name
            let req = Self.makeSaveRequest()
            req.add(mutable, toContainerWithIdentifier: nil)
            try store.execute(req)
            // `identifier` is assigned by Contacts at execute() time and is
            // readable on the same CNMutableGroup instance afterwards.
            return ContactGroup(localID: mutable.identifier, name: mutable.name)
        }
    }

    public func renameGroup(localID: String, to name: String) async throws {
        try await runOnWorkQueue { store in
            let predicate = CNGroup.predicateForGroups(withIdentifiers: [localID])
            let cnGroups = try store.groups(matching: predicate)
            guard let cn = cnGroups.first else {
                throw ContactStoreError.groupNotFound(localID: localID)
            }
            // mutableCopy() on a CNGroup always returns CNMutableGroup.
            let mutable = cn.mutableCopy() as! CNMutableGroup
            mutable.name = name
            let req = Self.makeSaveRequest()
            req.update(mutable)
            try store.execute(req)
        }
    }

    public func deleteGroup(localID: String) async throws {
        try await runOnWorkQueue { store in
            let predicate = CNGroup.predicateForGroups(withIdentifiers: [localID])
            let cnGroups = try store.groups(matching: predicate)
            guard let cn = cnGroups.first else {
                throw ContactStoreError.groupNotFound(localID: localID)
            }
            let mutable = cn.mutableCopy() as! CNMutableGroup
            let req = Self.makeSaveRequest()
            req.delete(mutable)
            try store.execute(req)
        }
    }

    public func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        try await runOnWorkQueue { store in
            // Verify the group exists so callers get a typed error instead
            // of an empty array when they pass a bad id.
            let groupPredicate = CNGroup.predicateForGroups(withIdentifiers: [groupLocalID])
            let cnGroups = try store.groups(matching: groupPredicate)
            guard cnGroups.first != nil else {
                throw ContactStoreError.groupNotFound(localID: groupLocalID)
            }
            let membersPredicate = CNContact.predicateForContactsInGroup(withIdentifier: groupLocalID)
            let cnContacts = try store.unifiedContacts(matching: membersPredicate, keysToFetch: Self.keys)
            return cnContacts.map(Self.toContact)
        }
    }

    public func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] {
        try await runOnWorkQueue { store in
            // Confirm the contact exists so a bad id throws instead of
            // returning an empty list. groupsContainingContact has no built-in
            // existence check.
            do {
                _ = try store.unifiedContact(
                    withIdentifier: contactLocalID,
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                )
            } catch let error as CNError where error.code == .recordDoesNotExist {
                throw ContactStoreError.contactNotFound(localID: contactLocalID)
            }
            // Walk all groups and filter by membership. CNGroup has no direct
            // "groups containing contact" API, so this is the supported path.
            let allGroups = try store.groups(matching: nil)
            var memberships: [ContactGroup] = []
            for g in allGroups {
                let membersPredicate = CNContact.predicateForContactsInGroup(withIdentifier: g.identifier)
                let members = try store.unifiedContacts(
                    matching: membersPredicate,
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                )
                if members.contains(where: { $0.identifier == contactLocalID }) {
                    memberships.append(ContactGroup(localID: g.identifier, name: g.name))
                }
            }
            return memberships
        }
    }

    public func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {
        try await runOnWorkQueue { store in
            let (contact, group) = try Self.resolveContactAndGroup(
                contactLocalID: contactLocalID,
                groupLocalID: groupLocalID,
                store: store
            )
            let req = Self.makeSaveRequest()
            req.addMember(contact, to: group)
            try store.execute(req)
        }
    }

    public func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {
        try await runOnWorkQueue { store in
            let (contact, group) = try Self.resolveContactAndGroup(
                contactLocalID: contactLocalID,
                groupLocalID: groupLocalID,
                store: store
            )
            let req = Self.makeSaveRequest()
            req.removeMember(contact, from: group)
            try store.execute(req)
        }
    }

    private static func resolveContactAndGroup(
        contactLocalID: String,
        groupLocalID: String,
        store: CNContactStore
    ) throws -> (CNContact, CNGroup) {
        let contact: CNContact
        do {
            contact = try store.unifiedContact(
                withIdentifier: contactLocalID,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
        } catch let error as CNError where error.code == .recordDoesNotExist {
            throw ContactStoreError.contactNotFound(localID: contactLocalID)
        }
        let groupPredicate = CNGroup.predicateForGroups(withIdentifiers: [groupLocalID])
        let cnGroups = try store.groups(matching: groupPredicate)
        guard let group = cnGroups.first else {
            throw ContactStoreError.groupNotFound(localID: groupLocalID)
        }
        return (contact, group)
    }

    /// Calls the Objective-C shim that performs the Swift-unavailable
    /// `enumeratorForChangeHistoryFetchRequest:error:` fetch, translating the
    /// C-style `NSError` out-parameter into a Swift throw. Returns the ordered
    /// change-history events; `token` is set to the resulting history token.
    private static func runChangeHistoryFetch(
        store: CNContactStore,
        request: CNChangeHistoryFetchRequest,
        token: inout NSData?
    ) throws -> [CNChangeHistoryEvent] {
        var error: NSError?
        let events = GWSyncFetchContactChangeHistory(store, request, &token, &error)
        if let error {
            throw error
        }
        return events ?? []
    }

    /// Bridge the blocking `CNContactStore` call onto `workQueue` and suspend
    /// the actor until it returns. Freeing the actor's thread for the
    /// synchronous CN/XPC work is what keeps a `@MainActor` caller's high-QoS
    /// Task off a lower-QoS actor executor (the priority-inversion warning).
    private func runOnWorkQueue<T>(
        _ work: @escaping @Sendable (CNContactStore) throws -> sending T
    ) async throws -> sending T {
        let store = self.store
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            workQueue.async {
                do {
                    let value = try work(store)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // The CN→Contact and Contact→CN mapping pair. Internal (not private) so
    // @testable tests can drive both directions against in-memory
    // CNMutableContact fixtures — constructing CN objects needs no Contacts
    // permission; only store fetches/saves do.
    static func toContact(_ c: CNContact) -> Contact {
        Contact(
            localID: c.identifier,
            contactType: c.contactType == .organization ? .organization : .person,
            namePrefix: c.namePrefix,
            givenName: c.givenName,
            middleName: c.middleName,
            familyName: c.familyName,
            previousFamilyName: c.previousFamilyName,
            nameSuffix: c.nameSuffix,
            nickname: c.nickname,
            phoneticGivenName: c.phoneticGivenName,
            phoneticMiddleName: c.phoneticMiddleName,
            phoneticFamilyName: c.phoneticFamilyName,
            jobTitle: c.jobTitle,
            departmentName: c.departmentName,
            organizationName: c.organizationName,
            phoneticOrganizationName: c.phoneticOrganizationName,
            note: c.note ?? "",
            phoneNumbers: c.phoneNumbers.map { LabeledValue(label: $0.label ?? "", value: $0.value.stringValue) },
            emailAddresses: c.emailAddresses.map { LabeledValue(label: $0.label ?? "", value: $0.value as String) },
            postalAddresses: c.postalAddresses.map {
                LabeledPostalAddress(
                    label: $0.label ?? "",
                    value: PostalAddress(
                        street: $0.value.street,
                        subLocality: $0.value.subLocality,
                        city: $0.value.city,
                        subAdministrativeArea: $0.value.subAdministrativeArea,
                        state: $0.value.state,
                        postalCode: $0.value.postalCode,
                        country: $0.value.country,
                        isoCountryCode: $0.value.isoCountryCode
                    )
                )
            },
            urlAddresses: c.urlAddresses.map { LabeledValue(label: $0.label ?? "", value: $0.value as String) },
            birthday: c.birthday,
            nonGregorianBirthday: c.nonGregorianBirthday,
            dates: c.dates.map { LabeledDate(label: $0.label ?? "", value: $0.value as DateComponents) },
            socialProfiles: c.socialProfiles.map {
                LabeledSocialProfile(
                    label: $0.label ?? "",
                    value: SocialProfile(
                        urlString: $0.value.urlString,
                        username: $0.value.username,
                        userIdentifier: $0.value.userIdentifier,
                        service: $0.value.service
                    )
                )
            },
            instantMessageAddresses: c.instantMessageAddresses.map {
                LabeledInstantMessageAddress(
                    label: $0.label ?? "",
                    value: InstantMessageAddress(
                        username: $0.value.username,
                        service: $0.value.service
                    )
                )
            },
            contactRelations: c.contactRelations.map {
                LabeledContactRelation(
                    label: $0.label ?? "",
                    value: ContactRelation(name: $0.value.name)
                )
            },
            imageDataAvailable: c.imageDataAvailable
        )
    }

    // See `toContact` above for the internal-for-@testable rationale.
    static func apply(_ contact: Contact, to mutable: CNMutableContact) {
        mutable.contactType = contact.contactType == .organization ? .organization : .person

        mutable.namePrefix = contact.namePrefix
        mutable.givenName = contact.givenName
        mutable.middleName = contact.middleName
        mutable.familyName = contact.familyName
        mutable.previousFamilyName = contact.previousFamilyName
        mutable.nameSuffix = contact.nameSuffix
        mutable.nickname = contact.nickname
        mutable.phoneticGivenName = contact.phoneticGivenName
        mutable.phoneticMiddleName = contact.phoneticMiddleName
        mutable.phoneticFamilyName = contact.phoneticFamilyName

        mutable.jobTitle = contact.jobTitle
        mutable.departmentName = contact.departmentName
        mutable.organizationName = contact.organizationName
        mutable.phoneticOrganizationName = contact.phoneticOrganizationName
        mutable.note = contact.note

        mutable.phoneNumbers = contact.phoneNumbers.map {
            CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: CNPhoneNumber(stringValue: $0.value))
        }
        mutable.emailAddresses = contact.emailAddresses.map {
            CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: $0.value as NSString)
        }
        mutable.postalAddresses = contact.postalAddresses.map { lv -> CNLabeledValue<CNPostalAddress> in
            let addr = CNMutablePostalAddress()
            addr.street = lv.value.street
            addr.subLocality = lv.value.subLocality
            addr.city = lv.value.city
            addr.subAdministrativeArea = lv.value.subAdministrativeArea
            addr.state = lv.value.state
            addr.postalCode = lv.value.postalCode
            addr.country = lv.value.country
            addr.isoCountryCode = lv.value.isoCountryCode
            return CNLabeledValue(label: lv.label.isEmpty ? nil : lv.label, value: addr)
        }
        mutable.urlAddresses = contact.urlAddresses.map {
            CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: $0.value as NSString)
        }

        mutable.birthday = contact.birthday
        mutable.nonGregorianBirthday = contact.nonGregorianBirthday
        mutable.dates = contact.dates.map { lv -> CNLabeledValue<NSDateComponents> in
            CNLabeledValue(label: lv.label.isEmpty ? nil : lv.label, value: lv.value as NSDateComponents)
        }

        mutable.socialProfiles = contact.socialProfiles.map { lv -> CNLabeledValue<CNSocialProfile> in
            let sp = CNSocialProfile(
                urlString: lv.value.urlString,
                username: lv.value.username,
                userIdentifier: lv.value.userIdentifier,
                service: lv.value.service
            )
            return CNLabeledValue(label: lv.label.isEmpty ? nil : lv.label, value: sp)
        }
        mutable.instantMessageAddresses = contact.instantMessageAddresses.map { lv -> CNLabeledValue<CNInstantMessageAddress> in
            let im = CNInstantMessageAddress(username: lv.value.username, service: lv.value.service)
            return CNLabeledValue(label: lv.label.isEmpty ? nil : lv.label, value: im)
        }
        mutable.contactRelations = contact.contactRelations.map { lv -> CNLabeledValue<CNContactRelation> in
            CNLabeledValue(label: lv.label.isEmpty ? nil : lv.label, value: CNContactRelation(name: lv.value.name))
        }

        // imageData / thumbnailImageData are not written here — the caller owns
        // them via a separate path. Leaving them untouched means a round-trip
        // read/modify/write preserves whatever bytes already exist on the
        // contact.
    }
}

/// Accumulates a contact change delta from the change-history enumeration.
/// Each `CNChangeHistoryEvent.accept(_:)` dispatches to the matching `visit`
/// method below, recording events in history order. Add and update both
/// collapse to `.updated`; delete becomes `.deleted`; drop-everything sets the
/// `droppedEverything` flag (the caller then forces a full reload). Group and
/// membership callbacks are intentionally unimplemented — the fetch request
/// sets `includeGroupChanges = false`, so they never fire.
private final class ChangeHistoryVisitor: NSObject, CNChangeHistoryEventVisitor {
    private(set) var changes: [ContactChange] = []
    private(set) var droppedEverything = false

    func visit(_ event: CNChangeHistoryAddContactEvent) {
        changes.append(.updated(localID: event.contact.identifier))
    }

    func visit(_ event: CNChangeHistoryUpdateContactEvent) {
        changes.append(.updated(localID: event.contact.identifier))
    }

    func visit(_ event: CNChangeHistoryDeleteContactEvent) {
        changes.append(.deleted(localID: event.contactIdentifier))
    }

    func visit(_ event: CNChangeHistoryDropEverythingEvent) {
        // Token invalidation / first-run / history truncation. The partial
        // delta is meaningless from here; clear it and signal a full reload.
        droppedEverything = true
        changes.removeAll()
    }
}

#endif
