import SwiftUI
import GuessWhoSync

struct PhoneticNameRow: View {
    @Binding var model: ContactEditModel
    @State private var expanded = false
    @FocusState private var focus: PhoneticField?

    private enum PhoneticField: Hashable {
        case given, middle, family
    }

    var body: some View {
        Section {
            DisclosureGroup("Phonetic Name", isExpanded: $expanded) {
                TextField("Phonetic First", text: $model.edited.phoneticGivenName)
                    .focused($focus, equals: .given)
                    .onSubmit { focus = .middle }
                    .onChange(of: model.edited.phoneticGivenName) { _, _ in model.isDirty = true }
                TextField("Phonetic Middle", text: $model.edited.phoneticMiddleName)
                    .focused($focus, equals: .middle)
                    .onSubmit { focus = .family }
                    .onChange(of: model.edited.phoneticMiddleName) { _, _ in model.isDirty = true }
                TextField("Phonetic Last", text: $model.edited.phoneticFamilyName)
                    .focused($focus, equals: .family)
                    .onChange(of: model.edited.phoneticFamilyName) { _, _ in model.isDirty = true }
            }
        }
    }
}
