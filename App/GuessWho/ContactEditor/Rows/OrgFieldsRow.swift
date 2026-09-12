import SwiftUI
import GuessWhoSync

struct OrgFieldsRow: View {
    @Binding var model: ContactEditModel
    // Optional: the new-contact sheet can be presented without a repository
    // in its environment, and the fields must still work — just without
    // suggestions.
    @Environment(ContactsRepository.self) private var repository: ContactsRepository?
    @FocusState private var focus: OrgField?

    private enum OrgField: Hashable {
        case organization, department, jobTitle
    }

    var body: some View {
        Section {
            // Return moves to the next field through the autocomplete's
            // `onSubmit`, not `.onSubmit`: the modifier takes Return first so
            // a highlighted suggestion is accepted instead.
            TextField("Company", text: $model.edited.organizationName)
                .focused($focus, equals: .organization)
                // Every organization name already in the contact book —
                // records and the company strings people carry.
                .autocomplete(text: $model.edited.organizationName, onSubmit: { focus = .department }) {
                    repository?.organizationNameSuggestionCandidates() ?? []
                }
                .onChange(of: model.edited.organizationName) { _, _ in model.isDirty = true }
                .centeredRowContent()
            TextField("Department", text: $model.edited.departmentName)
                .focused($focus, equals: .department)
                // Departments already used inside the Company named above;
                // nothing until that field is filled in.
                .autocomplete(text: $model.edited.departmentName, onSubmit: { focus = .jobTitle }) {
                    repository?.departmentNameSuggestionCandidates(
                        inOrganizationNamed: model.edited.organizationName
                    ) ?? []
                }
                .onChange(of: model.edited.departmentName) { _, _ in model.isDirty = true }
                .centeredRowContent()
            TextField("Job Title", text: $model.edited.jobTitle)
                .focused($focus, equals: .jobTitle)
                .onChange(of: model.edited.jobTitle) { _, _ in model.isDirty = true }
                .centeredRowContent()
            // Person vs. organization is an explicit Contacts flag (the
            // "Company" checkbox in macOS Contacts), NOT inferred from which
            // name fields are filled. It round-trips through
            // `CNContact.contactType` on save.
            Toggle("Organization", isOn: Binding(
                get: { model.edited.contactType == .organization },
                set: { model.edited.contactType = $0 ? .organization : .person }
            ))
            .onChange(of: model.edited.contactType) { _, _ in model.isDirty = true }
            .centeredRowContent()
        } header: {
            Text("Organization").centeredSectionHeader()
        } footer: {
            Text("Organizations appear in their own list, separate from People.")
                .centeredSectionFooter()
        }
    }
}
