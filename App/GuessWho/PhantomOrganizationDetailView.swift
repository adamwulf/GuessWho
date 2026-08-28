import SwiftUI
import GuessWhoSync
import GuessWhoLogging

/// Page for a "phantom" organization — a company named on people's cards that
/// has no organization record of its own yet (see `PhantomOrganization`). While
/// it is still a phantom it shows the company name, the people who name it, and
/// the departments they list, plus a single action to CREATE a real organization
/// card. Nothing here mutates Contacts until the user taps that button: opening
/// a phantom never mints a record (product decision — phantoms stay virtual
/// until asked for).
///
/// The moment a record with this name exists — this page created one, or one
/// appeared elsewhere — the page BECOMES that organization's real card in place
/// by rendering `ContactDetailView`. So "Create organization card" turns this
/// very card into the real, editable org right where the user is looking,
/// without a separate navigation step.
///
/// Identity is the normalized `key`; `displayName` is the spelling shown. All
/// content is read live from the repository (an `@Observable`), so an edit — or
/// the create — repaints the page.
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
        // card (their own spelling). `phantom` is nil once a record exists — fall
        // back to the passed name.
        let phantom = repository.phantomOrganization(key: key)
        let name = phantom?.displayName ?? displayName

        // The instant a record with this name exists (this page created it, or
        // one appeared elsewhere), BECOME its real card in place — reading it back
        // through the repository is @Observable, so the create re-renders here and
        // swaps the phantom UI for the real ContactDetailView with no navigation.
        if let record = repository.organizationContact(named: name) {
            ContactDetailView(id: record.contactID)
        } else {
            phantomBody(name: name, associatedCount: phantom?.associatedCount)
        }
    }

    @ViewBuilder
    private func phantomBody(name: String, associatedCount: Int?) -> some View {
        let people = repository.contactsAssociated(withOrganizationNamed: name)
        let departments = repository.departments(inOrganizationNamed: name)
        let count = associatedCount ?? people.count

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
                createCardRow(name: name)
                    .centeredRowContent()
            } footer: {
                Text("This company appears on \(peopleCountText(count)), but has no contact of its own. Create one to add notes, a photo, and more.")
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

    /// The create action. On tap it creates the real record; `body` then re-reads
    /// the repository, finds the record, and swaps this whole page for the real
    /// `ContactDetailView` in place — no separate navigation. Shown only while the
    /// company is still a phantom (the record-exists branch never renders this).
    private func createCardRow(name: String) -> some View {
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

    /// Create a real organization record carrying this company's name. No
    /// navigation: once the record exists the people who named it associate with
    /// it automatically, and `body` re-renders this page AS the real card in
    /// place (see the type doc). The `@Observable` repository drives that swap.
    private func createCard(name: String) {
        guard !isCreating else { return }
        isCreating = true
        Task { @MainActor in
            defer { isCreating = false }
            do {
                _ = try await repository.createContact(
                    Contact(contactType: .organization, organizationName: name)
                )
                Self.log.notice("phantom-org: created organization card for \(name)")
            } catch {
                Self.log.error("phantom-org: create failed: \(error.localizedDescription)")
            }
        }
    }
}
