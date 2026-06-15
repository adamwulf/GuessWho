#if canImport(Contacts)
import Contacts
import Foundation

public final class CNContactStoreAdapter: ContactStoreProtocol {
    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    private static let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
    ]

    public func fetchAll() throws -> [Contact] {
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        var results: [Contact] = []
        try store.enumerateContacts(with: request) { cnContact, _ in
            results.append(Self.toContact(cnContact))
        }
        return results
    }

    public func fetch(localID: String) throws -> Contact? {
        do {
            let cnContact = try store.unifiedContact(withIdentifier: localID, keysToFetch: Self.keys)
            return Self.toContact(cnContact)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        }
    }

    public func save(_ contact: Contact) throws {
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

    private static func toContact(_ c: CNContact) -> Contact {
        Contact(
            localID: c.identifier,
            givenName: c.givenName,
            familyName: c.familyName,
            organizationName: c.organizationName,
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
            birthday: c.birthday
        )
    }

    private static func apply(_ contact: Contact, to mutable: CNMutableContact) {
        mutable.givenName = contact.givenName
        mutable.familyName = contact.familyName
        mutable.organizationName = contact.organizationName
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
    }
}

#endif
