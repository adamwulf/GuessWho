import SwiftUI
import GuessWhoSync
import GuessWhoLogging

/// Read-only page for a "phantom" organization — a company named on people's
/// cards that has no organization record of its own yet (see
/// `PhantomOrganization`). It shows the company name, the people who name it,
/// and the departments they list, plus a single action to CREATE a real
/// organization card. Nothing here mutates Contacts until the user taps that
/// button: opening a phantom never mints a record (product decision — phantoms
/// stay virtual until asked for).
///
/// Identity is the normalized `key`; `displayName` is the spelling shown. The
/// associated people and departments are read live from the repository (an
/// `@Observable`), so an edit elsewhere repaints this page, and creating the
/// card navigates straight to the now-real record.
@MainActor
struct PhantomOrganizationDetailView: View {
    @Environment(ContactsRepository.self) private var repository
    @Environment(\.pushContactReference) private var pushContactReference

    let key: String
    let displayName: String

    /// The synthesized, name-only organization used purely to render the avatar
    /// monogram + color the same way a real organization row would.
    private var avatarContact: Contact {
        Contact(contactType: .organization, organizationName: displayName)
    }

    /// True while the create-card write is in flight, so the button shows
    /// progress and can't be tapped twice.
    @State private var isCreating = false

    private static let log = GuessWhoLog.logger("app.phantom-org")

    var body: some View {
        let people = repository.contactsAssociated(withOrganizationNamed: displayName)
        let departments = repository.departments(inOrganizationNamed: displayName)
        // Read live so the page self-corrects: if a record with this name comes
        // to exist (this page created one, or one appeared elsewhere), the action
        // switches from "Create" to "Open" and no duplicate can be made.
        let existingRecord = repository.organizationContact(named: displayName)

        let list = List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .centeredRowContent(alignment: .center)
                    .listRowInsets(EdgeInsets(top: 24, leading: 0, bottom: 16, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                actionRow(existingRecord: existingRecord)
                    .centeredRowContent()
            } footer: {
                Text(existingRecord == nil
                    ? "This company appears on \(peopleCountText(people.count)), but has no contact of its own. Create one to add notes, a photo, and more."
                    : "This company now has a contact of its own.")
                    .centeredRowContent()
            }

            if !people.isEmpty {
                Section {
                    ForEach(people, id: \.contactID) { person in
                        personRow(person)
                            .centeredRowContent()
                    }
                } header: {
                    Text("Associated Contacts").centeredSectionHeader()
                }
            }

            if !departments.isEmpty {
                Section {
                    ForEach(departments, id: \.self) { department in
                        Text(department)
                            .centeredRowContent()
                    }
                } header: {
                    Text("Departments").centeredSectionHeader()
                }
            }
        }
        .navigationTitle(displayName)

        #if targetEnvironment(macCatalyst)
        list.listStyle(.inset)
        #else
        list.listStyle(.insetGrouped)
        #endif
    }

    private var header: some View {
        VStack(spacing: 10) {
            ContactAvatar(contact: avatarContact, diameter: 96)
            Text(displayName)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
        }
    }

    /// The single action row: create a real organization card, or — once one
    /// exists — open it. `existingRecord` is resolved live in `body`.
    @ViewBuilder
    private func actionRow(existingRecord: Contact?) -> some View {
        if let existingRecord {
            Button {
                pushContactReference(ContactReference(id: existingRecord.contactID))
            } label: {
                Label("Open organization card", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        } else {
            Button {
                createCard()
            } label: {
                HStack {
                    Label("Create organization card", systemImage: "plus.circle")
                    Spacer()
                    if isCreating {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(isCreating)
        }
    }

    private func personRow(_ person: Contact) -> some View {
        Button {
            pushContactReference(ContactReference(id: person.contactID))
        } label: {
            ActivityRowLayout {
                ContactAvatar(contact: person, diameter: 20)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .foregroundStyle(.tint)
                    if !person.jobTitle.isEmpty {
                        Text(person.jobTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func peopleCountText(_ count: Int) -> String {
        count == 1 ? "1 contact" : "\(count) contacts"
    }

    /// Create a real organization record carrying this company's name, then
    /// navigate to it. Once the record exists the name is no longer a phantom —
    /// the people who named it associate with the real card automatically — so
    /// this page is left behind for the record's own detail.
    private func createCard() {
        guard !isCreating else { return }
        isCreating = true
        Task { @MainActor in
            defer { isCreating = false }
            do {
                let created = try await repository.createContact(
                    Contact(contactType: .organization, organizationName: displayName)
                )
                Self.log.notice("phantom-org: created organization card for \(displayName)")
                pushContactReference(ContactReference(id: created.contactID))
            } catch {
                Self.log.error("phantom-org: create failed: \(error.localizedDescription)")
            }
        }
    }
}
