import Foundation
import SwiftUI

struct ContactReference: Hashable {
    let localID: String
}

struct EventReference: Hashable {
    let eventUUID: String
    /// Optional EventKit identifier carried as a hint so the detail view can
    /// adopt an ephemeral EventKit row (one whose `eventUUID` is a synthetic
    /// `Event.stableID(forEventKitID:)`, not a real sidecar UUID). NOT part
    /// of identity — see Hashable/Equatable below — so the same underlying
    /// event pushed with vs. without the hint is treated as one stack entry.
    let eventKitID: String?

    init(eventUUID: String, eventKitID: String? = nil) {
        self.eventUUID = eventUUID.lowercased()
        self.eventKitID = eventKitID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(eventUUID)
    }

    static func == (lhs: EventReference, rhs: EventReference) -> Bool {
        lhs.eventUUID == rhs.eventUUID
    }
}

extension View {
    /// Register both Contact and Event navigation destinations so a single
    /// NavigationStack can push between them in either direction.
    func contactAndEventDestinations() -> some View {
        self
            .navigationDestination(for: ContactReference.self) { ref in
                ContactDetailView(localID: ref.localID)
            }
            .navigationDestination(for: EventReference.self) { ref in
                EventDetailView(eventUUID: ref.eventUUID, eventKitID: ref.eventKitID)
            }
    }
}
