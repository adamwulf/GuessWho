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

public actor CNContactStoreAdapter: ContactStoreProtocol {
    private let store: CNContactStore

    /// Dedicated serial queue that runs every blocking CNContactStore call.
    /// Pinned to `.userInitiated` so the actor's executor — which can be
    /// provisioned at Background QoS by the Swift concurrency runtime when
    /// the cooperative pool decides so — does NOT end up blocking a higher-
    /// QoS caller (e.g. the `@MainActor` SyncService) on a lower-QoS thread.
    ///
    /// Without this, calling `await contactsAdapter.fetchAll()` from
    /// `@MainActor` (User-Initiated) triggers a "Hang Risk: priority
    /// inversion" warning from the runtime because
    /// `CNContactStore.enumerateContacts` synchronously XPCs to a daemon
    /// at whatever QoS the actor's thread inherits, which is sometimes
    /// Background.
    private let workQueue = DispatchQueue(
        label: "guesswho.contacts-adapter",
        qos: .userInitiated
    )

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    private static let keys: [CNKeyDescriptor] = [
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

        // NOTE: CNContactNoteKey deliberately omitted (PLAN §10.5).
    ]

    private static let imageKeys: [CNKeyDescriptor] = [
        CNContactImageDataKey as CNKeyDescriptor,
    ]

    private static let thumbnailKeys: [CNKeyDescriptor] = [
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
    ]

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
            let saveRequest = CNSaveRequest()
            let existing = try? store.unifiedContact(withIdentifier: contact.localID, keysToFetch: Self.keys)
            if let existing, let mutable = existing.mutableCopy() as? CNMutableContact {
                Self.apply(contact, to: mutable)
                saveRequest.update(mutable)
            } else {
                let mutable = CNMutableContact()
                Self.apply(contact, to: mutable)
                saveRequest.add(mutable, toContainerWithIdentifier: nil)
            }
            try store.execute(saveRequest)
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
            let req = CNSaveRequest()
            req.delete(mutable)
            try store.execute(req)
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

    /// Bridge the blocking `CNContactStore` call onto `workQueue` and
    /// suspend the actor until it returns. The actor's thread is freed
    /// for the duration of the synchronous CN/XPC work, so a `@MainActor`
    /// caller no longer sees its high-QoS Task waiting on a lower-QoS
    /// actor executor (the priority-inversion warning).
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

    private static func toContact(_ c: CNContact) -> Contact {
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

    private static func apply(_ contact: Contact, to mutable: CNMutableContact) {
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

        // imageData / thumbnailImageData are not written here — they are owned
        // by the caller via a separate path. We do not mutate image bytes
        // here so a round-trip read/modify/write preserves whatever bytes
        // already exist on the contact (mirrors the §10.5 partial-update
        // guarantee for `note`).
    }
}

#endif
