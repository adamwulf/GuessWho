import Contacts
import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync

@Suite("Error.logContext")
struct ErrorLogContextTests {
    private enum UndescribedError: Error {
        case failed(status: Int32)
    }

    private struct PlainError: Error {}

    @Test
    func enumKeepsTheCaseAndPayloadItsDescriptionDrops() throws {
        let error = UndescribedError.failed(status: -34018)
        #expect(!error.localizedDescription.contains("-34018"))

        let errorCase = try #require(error.logContext()["errorCase"])
        #expect(errorCase.contains("failed(status: -34018)"))
    }

    @Test
    func keychainFailureKeepsItsStatus() {
        let context = SidecarBlobCryptoError.keychainStatus(-34018).logContext()
        #expect(context["errorCase"]?.contains("keychainStatus(-34018)") == true)
        #expect(context["error"]?.contains("-34018") == true)
    }

    @Test
    func rejectedFieldValueStaysOutOfTheContext() throws {
        let error = SidecarStoreError.typeValueMismatch(expected: .url, got: .string("private-value"))
        let context = error.logContext()

        let errorCase = try #require(context["errorCase"])
        #expect(errorCase.contains("typeValueMismatch"))
        #expect(!context.values.contains { $0.contains("private-value") })
    }

    @Test
    func nsErrorReportsDomainCodeAndUnderlyingWithoutUserInfo() throws {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 1)
        let error = NSError(domain: NSCocoaErrorDomain, code: 134092, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSFilePathErrorKey: "/Users/someone/private-file",
        ])

        let context = error.logContext()

        #expect(context["errorDomain"] == NSCocoaErrorDomain)
        #expect(context["errorCode"] == "134092")
        #expect(context["underlyingDomain"] == NSPOSIXErrorDomain)
        #expect(context["underlyingCode"] == "1")
        #expect(context["errorCase"] == nil)
        #expect(!context.values.contains { $0.contains("private-file") })
    }

    @Test
    func logCodesLeaveOutTheDescriptionThatNamesAFile() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 2)
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [
            NSUnderlyingErrorKey: underlying,
            NSLocalizedDescriptionKey: "The file “Jane Doe headshot.jpg” couldn’t be opened.",
        ])

        let codes = error.logCodes(["bytes": "12"])

        #expect(codes["bytes"] == "12")
        #expect(codes["errorDomain"] == NSCocoaErrorDomain)
        #expect(codes["errorCode"] == String(NSFileReadNoSuchFileError))
        #expect(codes["underlyingDomain"] == NSPOSIXErrorDomain)
        #expect(!codes.values.contains { $0.contains("Jane Doe") })
    }

    @Test
    func contactSaveFailureLeavesTheRejectedContactOut() {
        let contact = CNMutableContact()
        contact.givenName = "Private"
        contact.familyName = "Person"
        contact.phoneNumbers = [CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "555-0100"))]
        let validation = NSError(domain: CNErrorDomain, code: 300)
        let error = NSError(domain: CNErrorDomain, code: 300, userInfo: [
            CNErrorUserInfoAffectedRecordsKey: [contact],
            CNErrorUserInfoKeyPathsKey: ["givenName"],
            CNErrorUserInfoValidationErrorsKey: [validation],
        ])

        let metadata = CNContactStoreAdapter.saveFailureMetadata(error)
        let logged = metadata.values.map(\.description).joined(separator: " ")

        #expect(!logged.contains("Private"))
        #expect(!logged.contains("Person"))
        #expect(!logged.contains("555-0100"))
        #expect(metadata["userInfoKeys"]?.description.contains(CNErrorUserInfoAffectedRecordsKey) == true)
        #expect(metadata["keyPaths"]?.description == "givenName")
        #expect(metadata["validationErrors"]?.description == "\(CNErrorDomain)#300")
    }

    @Test
    func structErrorIsIdentifiedByItsDomain() throws {
        let context = PlainError().logContext()
        #expect(context["errorCase"] == nil)
        let domain = try #require(context["errorDomain"])
        #expect(domain.contains("PlainError"))
    }

    @Test
    func extraFieldsAreKeptAndErrorFieldsWin() {
        let context = PlainError().logContext(["name": "someone", "errorCode": "caller value"])
        #expect(context["name"] == "someone")
        #expect(context["errorCode"] != "caller value")
    }

    @Test
    func metadataCarriesTheSameFields() {
        let metadata = UndescribedError.failed(status: 7).logMetadata(["op": "write"])
        #expect(metadata["op"]?.description == "write")
        #expect(metadata["errorCase"]?.description.contains("failed(status: 7)") == true)
    }
}
