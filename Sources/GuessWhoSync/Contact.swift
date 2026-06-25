import Foundation

public struct Contact: Hashable, Sendable, Codable {
    public var localID: String
    public var contactType: ContactType

    // Names — full CNContact name family
    public var namePrefix: String
    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var previousFamilyName: String
    public var nameSuffix: String
    public var nickname: String
    public var phoneticGivenName: String
    public var phoneticMiddleName: String
    public var phoneticFamilyName: String

    // Work
    public var jobTitle: String
    public var departmentName: String
    public var organizationName: String
    public var phoneticOrganizationName: String

    // Addresses & contact channels
    public var phoneNumbers: [LabeledValue]
    public var emailAddresses: [LabeledValue]
    public var postalAddresses: [LabeledPostalAddress]
    public var urlAddresses: [LabeledValue]

    // Dates
    public var birthday: DateComponents?
    public var nonGregorianBirthday: DateComponents?
    public var dates: [LabeledDate]

    // Social / messaging / relations
    public var socialProfiles: [LabeledSocialProfile]
    public var instantMessageAddresses: [LabeledInstantMessageAddress]
    public var contactRelations: [LabeledContactRelation]

    // Image presence flag only — bytes loaded on demand
    public var imageDataAvailable: Bool

    public init(
        localID: String,
        contactType: ContactType = .person,
        namePrefix: String = "",
        givenName: String = "",
        middleName: String = "",
        familyName: String = "",
        previousFamilyName: String = "",
        nameSuffix: String = "",
        nickname: String = "",
        phoneticGivenName: String = "",
        phoneticMiddleName: String = "",
        phoneticFamilyName: String = "",
        jobTitle: String = "",
        departmentName: String = "",
        organizationName: String = "",
        phoneticOrganizationName: String = "",
        phoneNumbers: [LabeledValue] = [],
        emailAddresses: [LabeledValue] = [],
        postalAddresses: [LabeledPostalAddress] = [],
        urlAddresses: [LabeledValue] = [],
        birthday: DateComponents? = nil,
        nonGregorianBirthday: DateComponents? = nil,
        dates: [LabeledDate] = [],
        socialProfiles: [LabeledSocialProfile] = [],
        instantMessageAddresses: [LabeledInstantMessageAddress] = [],
        contactRelations: [LabeledContactRelation] = [],
        imageDataAvailable: Bool = false
    ) {
        self.localID = localID
        self.contactType = contactType
        self.namePrefix = namePrefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.previousFamilyName = previousFamilyName
        self.nameSuffix = nameSuffix
        self.nickname = nickname
        self.phoneticGivenName = phoneticGivenName
        self.phoneticMiddleName = phoneticMiddleName
        self.phoneticFamilyName = phoneticFamilyName
        self.jobTitle = jobTitle
        self.departmentName = departmentName
        self.organizationName = organizationName
        self.phoneticOrganizationName = phoneticOrganizationName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.postalAddresses = postalAddresses
        self.urlAddresses = urlAddresses
        self.birthday = birthday
        self.nonGregorianBirthday = nonGregorianBirthday
        self.dates = dates
        self.socialProfiles = socialProfiles
        self.instantMessageAddresses = instantMessageAddresses
        self.contactRelations = contactRelations
        self.imageDataAvailable = imageDataAvailable
    }
}

extension Contact {
    /// This contact's opaque identity token. Derived purely from the contact's
    /// stored data (its `guesswho://` URL if reconciled, else its `localID`),
    /// so it's free to compute on demand. The canonical id shape the UI keys on.
    public var contactID: ContactID { ContactID(contact: self) }
}
