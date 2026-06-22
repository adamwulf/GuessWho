import SwiftUI
import GuessWhoSync

struct NameSection: View {
    @Binding var model: ContactEditModel
    @FocusState private var focus: NameField?

    private enum NameField: Hashable {
        case prefix, given, middle, family, suffix, nickname
    }

    var body: some View {
        Section {
            TextField("Prefix", text: $model.edited.namePrefix)
                .focused($focus, equals: .prefix)
                .onSubmit { focus = .given }
                .onChange(of: model.edited.namePrefix) { _, _ in model.isDirty = true }
            TextField("First", text: $model.edited.givenName)
                .focused($focus, equals: .given)
                .onSubmit { focus = .middle }
                .onChange(of: model.edited.givenName) { _, _ in model.isDirty = true }
            TextField("Middle", text: $model.edited.middleName)
                .focused($focus, equals: .middle)
                .onSubmit { focus = .family }
                .onChange(of: model.edited.middleName) { _, _ in model.isDirty = true }
            TextField("Last", text: $model.edited.familyName)
                .focused($focus, equals: .family)
                .onSubmit { focus = .suffix }
                .onChange(of: model.edited.familyName) { _, _ in model.isDirty = true }
            TextField("Suffix", text: $model.edited.nameSuffix)
                .focused($focus, equals: .suffix)
                .onSubmit { focus = .nickname }
                .onChange(of: model.edited.nameSuffix) { _, _ in model.isDirty = true }
            TextField("Nickname", text: $model.edited.nickname)
                .focused($focus, equals: .nickname)
                .onChange(of: model.edited.nickname) { _, _ in model.isDirty = true }
        }
    }
}
