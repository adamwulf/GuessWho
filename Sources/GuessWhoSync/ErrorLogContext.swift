import Foundation
import Logging

extension Error {
    /// The log fields that explain this error, merged over `extra`.
    /// `localizedDescription` alone can lose them: a Swift enum with no
    /// `LocalizedError` conformance renders as "The operation couldn’t be
    /// completed. (Module.Type error 0.)", with its case and payload gone.
    ///
    /// Developer-facing: these fields name types and codes, so they must never
    /// reach a user-visible string. Use `localizedDescription` there.
    public func logContext(_ extra: [String: String] = [:]) -> [String: String] {
        let nsError = self as NSError
        var context = extra
        context["error"] = localizedDescription
        context["errorDomain"] = nsError.domain
        context["errorCode"] = String(nsError.code)
        // Only an enum is reflected. NSError and the Foundation wrappers around
        // it (CocoaError, URLError, CNError) would print their userInfo, which
        // can hold file paths and contact fields. An enum whose payload can hold
        // user data must define a `debugDescription` that leaves it out, as
        // `SidecarStoreError` does.
        if Mirror(reflecting: self).displayStyle == .enum {
            context["errorCase"] = String(reflecting: self)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            context["underlyingDomain"] = underlying.domain
            context["underlyingCode"] = String(underlying.code)
        }
        return context
    }

    /// `logContext` as swift-log metadata. This package depends on swift-log
    /// directly, so the `GuessWhoLogging` overload that takes a plain dictionary
    /// isn't in scope here.
    func logMetadata(_ extra: Logger.Metadata = [:]) -> Logger.Metadata {
        extra.merging(logContext().mapValues { .string($0) }) { _, errorField in errorField }
    }
}
