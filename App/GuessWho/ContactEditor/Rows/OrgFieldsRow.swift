import SwiftUI
import GuessWhoSync

struct OrgFieldsRow: View {
    @Binding var model: ContactEditModel
    let focus: ContactEditorFocus
    // Optional: the new-contact sheet can be presented without a repository
    // in its environment, and the fields must still work — just without
    // suggestions.
    @Environment(ContactsRepository.self) private var repository: ContactsRepository?

    var body: some View {
        TitledSection("Organization") {
            // Return moves to the next field through the autocomplete's
            // `onSubmit`, not `.onSubmit`: the modifier takes Return first so
            // a highlighted suggestion is accepted instead. Tab works the same
            // way, so `editorTabStop` comes after the autocomplete.
            TextField("Company", text: $model.edited.organizationName)
                .focused(focus, equals: .organizationName)
                // Every organization name already in the contact book —
                // records and the company strings people carry.
                .autocomplete(text: $model.edited.organizationName, onSubmit: { focus.wrappedValue = .departmentName }) {
                    repository?.organizationNameSuggestionCandidates() ?? []
                }
                .editorTabStop(focus)
                .onChange(of: model.edited.organizationName) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.organizationName)
            TextField("Department", text: $model.edited.departmentName)
                .focused(focus, equals: .departmentName)
                // Departments already used inside the Company named above;
                // nothing until that field is filled in.
                .autocomplete(text: $model.edited.departmentName, onSubmit: { focus.wrappedValue = .jobTitle }) {
                    repository?.departmentNameSuggestionCandidates(
                        inOrganizationNamed: model.edited.organizationName
                    ) ?? []
                }
                .editorTabStop(focus)
                .onChange(of: model.edited.departmentName) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.departmentName)
            TextField("Job Title", text: $model.edited.jobTitle)
                .focused(focus, equals: .jobTitle)
                .editorTabStop(focus)
                .onChange(of: model.edited.jobTitle) { _, _ in model.isDirty = true }
                .centeredRowContent()
                .editorRow(.jobTitle)
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
        } footer: {
            Text("Organizations appear in their own list, separate from People.")
                .centeredSectionFooter()
        }
    }
}
