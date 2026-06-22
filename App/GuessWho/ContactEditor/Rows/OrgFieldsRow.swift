import SwiftUI
import GuessWhoSync

struct OrgFieldsRow: View {
    @Binding var model: ContactEditModel
    @FocusState private var focus: OrgField?

    private enum OrgField: Hashable {
        case organization, department, jobTitle
    }

    var body: some View {
        Section("Organization") {
            TextField("Company", text: $model.edited.organizationName)
                .focused($focus, equals: .organization)
                .onSubmit { focus = .department }
                .onChange(of: model.edited.organizationName) { _, _ in model.isDirty = true }
            TextField("Department", text: $model.edited.departmentName)
                .focused($focus, equals: .department)
                .onSubmit { focus = .jobTitle }
                .onChange(of: model.edited.departmentName) { _, _ in model.isDirty = true }
            TextField("Job Title", text: $model.edited.jobTitle)
                .focused($focus, equals: .jobTitle)
                .onChange(of: model.edited.jobTitle) { _, _ in model.isDirty = true }
        }
    }
}
