import Foundation

public struct PostalAddress: Hashable, Sendable, Codable {
    public var street: String
    public var subLocality: String
    public var city: String
    public var subAdministrativeArea: String
    public var state: String
    public var postalCode: String
    public var country: String
    public var isoCountryCode: String

    public init(
        street: String = "",
        subLocality: String = "",
        city: String = "",
        subAdministrativeArea: String = "",
        state: String = "",
        postalCode: String = "",
        country: String = "",
        isoCountryCode: String = ""
    ) {
        self.street = street
        self.subLocality = subLocality
        self.city = city
        self.subAdministrativeArea = subAdministrativeArea
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }
}
