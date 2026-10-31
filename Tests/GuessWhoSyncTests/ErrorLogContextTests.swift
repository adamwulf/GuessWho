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
