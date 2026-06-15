import Foundation

public struct IdentityReconcileReport: Sendable {
    public struct ContactOutcome: Sendable {
        public let localID: String
        public let assignedUUID: String?
        public let mergedLoserUUIDs: [String]
        public let removedMalformedURLs: [String]
        public let errors: [String]

        public init(
            localID: String,
            assignedUUID: String?,
            mergedLoserUUIDs: [String],
            removedMalformedURLs: [String],
            errors: [String]
        ) {
            self.localID = localID
            self.assignedUUID = assignedUUID
            self.mergedLoserUUIDs = mergedLoserUUIDs
            self.removedMalformedURLs = removedMalformedURLs
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
