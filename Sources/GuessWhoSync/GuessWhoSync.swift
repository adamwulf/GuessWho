import Foundation

public final class GuessWhoSync {
    private let contacts: ContactStoreProtocol
    private let events: EventStoreProtocol
    private let sidecars: SidecarStoreProtocol
    private let deviceID: String
    private let sidecarLocks = PerKeyLockTable<SidecarKey>()

    public init(
        contacts: ContactStoreProtocol,
        events: EventStoreProtocol,
        sidecars: SidecarStoreProtocol,
        deviceID: String
    ) {
        self.contacts = contacts
        self.events = events
        self.sidecars = sidecars
        self.deviceID = deviceID
    }

    public func sidecar(at key: SidecarKey) throws -> SidecarEnvelope? {
        try sidecars.read(key)
    }

    public func setField(_ name: String, value: JSONValue, at key: SidecarKey) throws {
        try sidecarLocks.withLock(forKey: key) {
            let existing = try sidecars.read(key)
            let cell = SidecarCell.value(value, modifiedAt: Date(), modifiedBy: deviceID)
            var fields = existing?.fields ?? [:]
            fields[name] = cell
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
        }
    }

    public func deleteField(_ name: String, at key: SidecarKey) throws {
        try sidecarLocks.withLock(forKey: key) {
            let existing = try sidecars.read(key)
            let tombstone = SidecarCell.tombstone(modifiedAt: Date(), modifiedBy: deviceID)
            var fields = existing?.fields ?? [:]
            fields[name] = tombstone
            let envelope = SidecarEnvelope(
                schemaVersion: 1,
                entityID: existing?.entityID ?? key.id,
                fields: fields
            )
            try sidecars.write(envelope, at: key)
        }
    }

    public func reconcileSidecars() throws -> SidecarReconcileReport {
        var reasonsByKey: [SidecarKey: [String]] = [:]

        let outcomes = try sidecars.reconcileConflicts { key, versions in
            var parsed: [SidecarEnvelope] = []
            var skipped: [Data] = []
            var reasons: [String] = []

            for bytes in versions {
                switch parseEnvelope(bytes) {
                case .ok(let envelope):
                    parsed.append(envelope)
                case .skip(let reason):
                    skipped.append(bytes)
                    reasons.append(reason)
                }
            }

            reasonsByKey[key] = reasons

            guard var folded = parsed.first else {
                return .leave
            }
            for next in parsed.dropFirst() {
                switch merge(folded, next) {
                case .success(let combined):
                    folded = combined
                case .failure(let err):
                    reasons.append("merge failed: \(err)")
                    reasonsByKey[key] = reasons
                    return .leave
                }
            }
            return .write(merged: folded, skip: skipped)
        }

        let stamped = outcomes.map { outcome -> SidecarReconcileReport.FileOutcome in
            let extra = reasonsByKey[outcome.key] ?? []
            return SidecarReconcileReport.FileOutcome(
                key: outcome.key,
                mergedVersionCount: outcome.mergedVersionCount,
                skippedReasons: outcome.skippedReasons + extra
            )
        }
        return SidecarReconcileReport(fileOutcomes: stamped)
    }

    public func reconcileContactIdentities() throws -> IdentityReconcileReport {
        var outcomes: [IdentityReconcileReport.ContactOutcome] = []
        var carriedUUIDs: Set<String> = []

        for contact in try contacts.fetchAll() {
            let outcome = try reconcile(contact: contact)
            outcomes.append(outcome.report)
            carriedUUIDs.formUnion(outcome.carriedUUIDs)
        }

        let orphans = try sidecars.allKeys()
            .filter { $0.kind == .contact && !carriedUUIDs.contains($0.id) }
            .sorted { $0.id < $1.id }

        return IdentityReconcileReport(contactOutcomes: outcomes, orphanSidecars: orphans)
    }

    private struct ContactReconcileResult {
        let report: IdentityReconcileReport.ContactOutcome
        let carriedUUIDs: [String]
    }

    private func reconcile(contact original: Contact) throws -> ContactReconcileResult {
        var contact = original
        var uniqueValidUUIDs: [String] = []
        var seenUUIDs: Set<String> = []
        var hadDuplicateUUID = false
        var malformedURLs: [String] = []

        for url in contact.urlAddresses {
            guard url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix) else { continue }
            if let uuid = SidecarKey.parseGuessWhoContactURL(url.value) {
                if seenUUIDs.insert(uuid).inserted {
                    uniqueValidUUIDs.append(uuid)
                } else {
                    hadDuplicateUUID = true
                }
            } else {
                malformedURLs.append(url.value)
            }
        }

        // Collapse repeat occurrences of the SAME canonical UUID down to one URL entry,
        // so only DIFFERENT canonical UUIDs reach Case D's keep-smaller-delete-larger logic.
        if hadDuplicateUUID {
            var keptUUIDs: Set<String> = []
            contact.urlAddresses.removeAll { url in
                guard url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix),
                      let uuid = SidecarKey.parseGuessWhoContactURL(url.value)
                else { return false }
                return !keptUUIDs.insert(uuid).inserted
            }
        }

        switch uniqueValidUUIDs.count {
        case 0:
            return try handleCaseA(contact: &contact, malformedURLs: malformedURLs)
        case 1 where malformedURLs.isEmpty && !hadDuplicateUUID:
            return ContactReconcileResult(
                report: IdentityReconcileReport.ContactOutcome(
                    localID: contact.localID,
                    assignedUUID: nil,
                    mergedLoserUUIDs: [],
                    removedMalformedURLs: [],
                    errors: []
                ),
                carriedUUIDs: uniqueValidUUIDs
            )
        case 1 where malformedURLs.isEmpty:
            // Duplicate URL entries collapsed; persist the trimmed contact, no other changes.
            try contacts.save(contact)
            return ContactReconcileResult(
                report: IdentityReconcileReport.ContactOutcome(
                    localID: contact.localID,
                    assignedUUID: nil,
                    mergedLoserUUIDs: [],
                    removedMalformedURLs: [],
                    errors: []
                ),
                carriedUUIDs: uniqueValidUUIDs
            )
        case 1:
            return try handleCaseC(contact: &contact, validUUID: uniqueValidUUIDs[0], malformedURLs: malformedURLs)
        default:
            return try handleCaseD(contact: &contact, validUUIDs: uniqueValidUUIDs, malformedURLs: malformedURLs)
        }
    }

    private func handleCaseA(
        contact: inout Contact,
        malformedURLs: [String]
    ) throws -> ContactReconcileResult {
        contact.urlAddresses.removeAll { url in
            url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        let newUUID = UUID().uuidString.lowercased()
        contact.urlAddresses.append(
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + newUUID)
        )
        try contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: newUUID,
                mergedLoserUUIDs: [],
                removedMalformedURLs: malformedURLs,
                errors: []
            ),
            carriedUUIDs: [newUUID]
        )
    }

    private func handleCaseC(
        contact: inout Contact,
        validUUID: String,
        malformedURLs: [String]
    ) throws -> ContactReconcileResult {
        contact.urlAddresses.removeAll { url in
            url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        try contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: nil,
                mergedLoserUUIDs: [],
                removedMalformedURLs: malformedURLs,
                errors: []
            ),
            carriedUUIDs: [validUUID]
        )
    }

    private func handleCaseD(
        contact: inout Contact,
        validUUIDs: [String],
        malformedURLs: [String]
    ) throws -> ContactReconcileResult {
        let sortedUUIDs = validUUIDs.sorted()
        let winner = sortedUUIDs[0]
        let losers = Array(sortedUUIDs.dropFirst())

        let winnerKey = SidecarKey(kind: .contact, id: winner)
        var merged = try sidecars.read(winnerKey)
            ?? SidecarEnvelope(entityID: winner, fields: [:])

        var mergedLoserUUIDs: [String] = []
        var errors: [String] = []
        for loser in losers {
            let loserKey = SidecarKey(kind: .contact, id: loser)
            guard let loserEnvelope = try sidecars.read(loserKey) else { continue }
            let rebased = SidecarEnvelope(
                schemaVersion: loserEnvelope.schemaVersion,
                entityID: winner,
                fields: loserEnvelope.fields
            )
            switch merge(merged, rebased) {
            case .success(let next):
                merged = next
                mergedLoserUUIDs.append(loser)
            case .failure(let err):
                errors.append("merge failed for loser \(loser): \(err)")
            }
        }

        try sidecars.write(merged, at: winnerKey)
        for loser in losers {
            try sidecars.delete(SidecarKey(kind: .contact, id: loser))
        }

        let loserURLs = Set(losers.map { SidecarKey.guessWhoContactURLPrefix + $0 })
        contact.urlAddresses.removeAll { url in
            if loserURLs.contains(url.value) { return true }
            return url.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
                && SidecarKey.parseGuessWhoContactURL(url.value) == nil
        }
        try contacts.save(contact)

        return ContactReconcileResult(
            report: IdentityReconcileReport.ContactOutcome(
                localID: contact.localID,
                assignedUUID: nil,
                mergedLoserUUIDs: mergedLoserUUIDs,
                removedMalformedURLs: malformedURLs,
                errors: errors
            ),
            carriedUUIDs: [winner]
        )
    }
}

private enum ParseOutcome {
    case ok(SidecarEnvelope)
    case skip(String)
}

private func parseEnvelope(_ data: Data) -> ParseOutcome {
    let envelope: SidecarEnvelope
    do {
        envelope = try JSONDecoder().decode(SidecarEnvelope.self, from: data)
    } catch {
        return .skip("bad JSON: \(error)")
    }
    guard envelope.schemaVersion == 1 else {
        return .skip("schemaVersion=\(envelope.schemaVersion)")
    }
    return .ok(envelope)
}
