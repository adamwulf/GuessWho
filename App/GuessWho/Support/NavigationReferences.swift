import Foundation
import SwiftUI

struct ContactReference: Hashable {
    let localID: String
}

struct EventReference: Hashable {
    let externalID: String
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
                EventDetailView(externalID: ref.externalID)
            }
    }
}

