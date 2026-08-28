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

    /// Normalized identity of the phantom (see `PhantomOrganization.key`). Used
    /// to resolve the canonical display name + count from the repository, so the
    /// page reads identically from either entry point.
    let key: String
    /// The spelling the entry point had on hand — a fallback for the header/title
    /// once a record exists and `key` no longer resolves to a phantom.
    let displayName: String

    /// True while the create-card write is in flight, so the button shows
    /// progress and can't be tapped twice.
    @State private var isCreating = false

    private static let log = GuessWhoLog.logger("app.phantom-org")

    var body: some View {
        // Resolve the CANONICAL name from the phantom projection by `key`, so the
        // title/header read the same whether this page was reached from the
        // Organizations list (which passes the canonical spelling) or a person's
        // card (their own spelling). `phantom` is nil once a record exists
        // (post-create, or one appeared elsewhere) — fall back to the passed name.
        let phantom = repository.phantomOrganization(key: key)
        let name = phantom?.displayName ?? displayName
        let people = repository.contactsAssociated(withOrganizationNamed: name)
        let departments = repository.departments(inOrganizationNamed: name)
        // Read live so the page self-corrects: if a record with this name comes
        // to exist, the action switches from "Create" to "Open" and no duplicate
        // can be made.
        let existingRecord = repository.organizationContact(named: name)
        let associatedCount = phantom?.associatedCount ?? people.count

        let list = List {
            Section {
                header(name: name)
                    .frame(maxWidth: .infinity)
                    .centeredRowContent(alignment: .center)
                    .listRowInsets(EdgeInsets(top: 24, leading: 0, bottom: 16, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                actionRow(existingRecord: existingRecord, name: name)
                    .centeredRowContent()
            } footer: {
                Text(existingRecord == nil
                    ? "This company appears on \(peopleCountText(associatedCount)), but has no contact of its own. Create one to add notes, a photo, and more."
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
        .navigationTitle(name)

        #if targetEnvironment(macCatalyst)
        list.listStyle(.inset)
        #else
        list.listStyle(.insetGrouped)
        #endif
    }

    private func header(name: String) -> some View {
        VStack(spacing: 10) {
            // Name-only synthesized org so the monogram initials + color match a
            // real organization row's placeholder.
            ContactAvatar(contact: Contact(contactType: .organization, organizationName: name), diameter: 96)
            Text(name)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
        }
    }

    /// The single action row: create a real organization card, or — once one
    /// exists — open it. `existingRecord` / `name` are resolved live in `body`.
    @ViewBuilder
    private func actionRow(existingRecord: Contact?, name: String) -> some View {
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
                createCard(name: name)
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
    private func createCard(name: String) {
        guard !isCreating else { return }
        isCreating = true
        Task { @MainActor in
            defer { isCreating = false }
            do {
                let created = try await repository.createContact(
                    Contact(contactType: .organization, organizationName: name)
                )
                Self.log.notice("phantom-org: created organization card for \(name)")
                pushContactReference(ContactReference(id: created.contactID))
            } catch {
                Self.log.error("phantom-org: create failed: \(error.localizedDescription)")
            }
        }
    }
}
