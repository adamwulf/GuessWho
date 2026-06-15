import Foundation

public struct IdentityReconcileReport: Sendable {
    public struct ContactOutcome: Sendable {
        public let localID: String
        public let assignedUUID: String?
        public let mergedLoserUUIDs: [String]
        public let removedMalformedURLs: [String]
        // §13.4 — link UUIDs whose endpoints were rewritten by this contact's
        // Case-D collapse. Each link appears at most once even if both its
        // endpoints were rewritten in one pass.
        public let rewrittenLinkIDs: [UUID]
        public let errors: [String]

        public init(
            localID: String,
            assignedUUID: String?,
            mergedLoserUUIDs: [String],
            removedMalformedURLs: [String],
            rewrittenLinkIDs: [UUID] = [],
            errors: [String]
        ) {
            self.localID = localID
            self.assignedUUID = assignedUUID
            self.mergedLoserUUIDs = mergedLoserUUIDs
            self.removedMalformedURLs = removedMalformedURLs
            self.rewrittenLinkIDs = rewrittenLinkIDs
            self.errors = errors
        }
    }

    public let contactOutcomes: [ContactOutcome]
    public let orphanSidecars: [SidecarKey]

    public init(contactOutcomes: [ContactOutcome], orphanSidecars: [SidecarKey]) {
        self.contactOutcomes = contactOutcomes
        self.orphanSidecars = orphanSidecars
    }
}
