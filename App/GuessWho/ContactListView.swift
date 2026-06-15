import SwiftUI
import GuessWhoSync

struct ContactListView: View {
    @Environment(SyncService.self) private var service

    @State private var contacts: [Contact] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            switch service.contactsAuthorization {
            case .notRequested:
                ContentUnavailableView(
                    "Requesting Contacts Access…",
                    systemImage: "person.2.fill",
                    description: Text("Approve the permission prompt to view your contacts.")
                )
            case .denied:
                deniedView
            case .restricted:
                ContentUnavailableView(
                    "Contacts Restricted",
                    systemImage: "lock",
                    description: Text("Contacts access is restricted on this device.")
                )
            case .authorized:
                authorizedList
            }
        }
        .overlay(alignment: .bottom) {
            sidecarLocationBanner
                .padding()
        }
    }

    private var authorizedList: some View {
        List {
            ForEach(sortedContacts, id: \.localID) { contact in
                NavigationLink(value: contact.localID) {
                    row(for: contact)
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if contacts.isEmpty {
                ContentUnavailableView(
                    "No Contacts",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("There are no contacts in this account.")
                )
            }
        }
        .refreshable {
            await reload()
        }
        .task {
            await reload()
        }
        .navigationDestination(for: String.self) { localID in
            ContactDetailView(localID: localID)
        }
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Contacts Access Needed",
                systemImage: "person.crop.circle.badge.xmark",
                description: Text("Open Settings and enable Contacts access for GuessWho.")
            )
        }
    }

    @ViewBuilder
    private var sidecarLocationBanner: some View {
        switch service.sidecarLocation {
        case .iCloud:
            EmptyView()
        case .localFallback(_, let reason):
            Label {
                Text(reason)
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row(for contact: Contact) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(displayName(for: contact))
                    .font(.body)
                if service.guessWhoUUID(in: contact) != nil {
                    Text("GuessWho ✓")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var sortedContacts: [Contact] {
        contacts.sorted { lhs, rhs in
            displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    private func displayName(for contact: Contact) -> String {
        let personName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        if !personName.isEmpty { return personName }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if !contact.nickname.isEmpty { return contact.nickname }
        return "(Unnamed)"
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        contacts = service.fetchAll()
    }
}
