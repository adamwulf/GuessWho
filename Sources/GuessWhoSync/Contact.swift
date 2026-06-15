import Foundation

public struct Contact: Hashable, Sendable {
    public var localID: String
    public var givenName: String
    public var familyName: String
    public var organizationName: String
    public var phoneNumbers: [LabeledValue]
    public var emailAddresses: [LabeledValue]
    public var postalAddresses: [LabeledValue]
    public var urlAddresses: [LabeledValue]
    public var birthday: DateComponents?

    public init(
        localID: String,
        givenName: String = "",
        familyName: String = "",
        organizationName: String = "",
        phoneNumbers: [LabeledValue] = [],
        emailAddresses: [LabeledValue] = [],
        postalAddresses: [LabeledValue] = [],
        urlAddresses: [LabeledValue] = [],
        birthday: DateComponents? = nil
    ) {
        self.localID = localID
        self.givenName = givenName
        self.familyName = familyName
        self.organizationName = organizationName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.postalAddresses = postalAddresses
        self.urlAddresses = urlAddresses
        self.birthday = birthday
    }
}
