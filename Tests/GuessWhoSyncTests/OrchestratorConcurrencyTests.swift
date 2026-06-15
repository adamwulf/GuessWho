import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("OrchestratorConcurrency")
struct OrchestratorConcurrencyTests {
    private let deviceID = "device-A"

    private func makeSync(
        sidecars: InMemorySidecarStore = InMemorySidecarStore()
    ) -> (GuessWhoSync, InMemorySidecarStore) {
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars)
    }

    /// Spawns 100 concurrent setField calls on the SAME key, each writing a distinct
    /// field. Without per-key serialization, read-modify-write races cause earlier
    /// writes to be clobbered and the final envelope contains far fewer than 100
    /// fields. With per-key serialization, all 100 fields land.
    @Test
    func concurrentSetFieldOnSameKeyPreservesAllWrites() throws {
        let (sync, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "key-same-A")
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? sync.setField("field-\(i)", value: .number(Double(i)), at: key)
        }

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == count, "expected \(count) fields, got \(envelope.fields.count)")
        for i in 0..<count {
            switch envelope.fields["field-\(i)"] {
            case let .value(v, _, _):
                #expect(v == .number(Double(i)))
            default:
                Issue.record("missing or wrong cell for field-\(i)")
            }
        }
    }

    /// Spawns 100 concurrent setField calls on 100 DIFFERENT keys. Each key should
    /// end up with exactly its one field. Validates that distinct keys do not
    /// serialize against each other (correctness, not timing).
    @Test
    func concurrentSetFieldOnDifferentKeysAllWriteCorrectly() throws {
        let (sync, sidecars) = makeSync()
        let count = 100
        let keys = (0..<count).map {
            SidecarKey(kind: .contact, id: "key-\($0)")
        }

        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? sync.setField("only", value: .number(Double(i)), at: keys[i])
        }

        for i in 0..<count {
            let envelope = try #require(try sidecars.read(keys[i]))
            #expect(envelope.fields.count == 1)
            switch envelope.fields["only"] {
            case let .value(v, _, _):
                #expect(v == .number(Double(i)))
            default:
                Issue.record("missing or wrong cell at key-\(i)")
            }
        }
    }

    /// Mixes 100 concurrent setField and deleteField calls on the SAME key for
    /// distinct field names — every (set X) and (delete Y) must result in a
    /// final envelope with all 100 cells present (either value or tombstone).
    @Test
    func concurrentSetAndDeleteOnSameKeyPreservesAllCells() throws {
        let (sync, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "key-same-B")
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { i in
            if i.isMultiple(of: 2) {
                try? sync.setField("field-\(i)", value: .number(Double(i)), at: key)
            } else {
                try? sync.deleteField("field-\(i)", at: key)
            }
        }

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == count)
        for i in 0..<count {
            let cell = envelope.fields["field-\(i)"]
            if i.isMultiple(of: 2) {
                switch cell {
                case let .value(v, _, _):
                    #expect(v == .number(Double(i)))
                default:
                    Issue.record("expected value cell for field-\(i)")
                }
            } else {
                switch cell {
                case .tombstone:
                    break
                default:
                    Issue.record("expected tombstone for field-\(i)")
                }
            }
        }
    }
}

