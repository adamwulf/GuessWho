import SwiftUI
import GuessWhoSync

struct RelationRow: View {
    @Binding var model: ContactEditModel
    // Optional: the new-contact sheet can be presented without a repository
    // in its environment, and the field must still work — just without
    // suggestions.
    @Environment(ContactsRepository.self) private var repository: ContactsRepository?

    var body: some View {
        Section {
            ForEach(model.edited.contactRelations.indices, id: \.self) { idx in
                let name = Binding<String>(
                    get: { model.edited.contactRelations[idx].value.name },
                    set: {
                        model.edited.contactRelations[idx] = LabeledContactRelation(
                            label: model.edited.contactRelations[idx].label,
                            value: ContactRelation(name: $0)
                        )
                        model.isDirty = true
                    }
                )
                HStack {
                    LabelPicker(
                        label: Binding(
                            get: { model.edited.contactRelations[idx].label },
                            set: {
                                model.edited.contactRelations[idx] = LabeledContactRelation(
                                    label: $0,
                                    value: model.edited.contactRelations[idx].value
                                )
                                model.isDirty = true
                            }
                        ),
                        options: LabelOptions.relation
                    )
                    TextField("Name", text: name)
                        // A relation resolves to a contact by display name
                        // (see the detail card), so suggest exactly those —
                        // every contact but this one.
                        .autocomplete(text: name) {
                            repository?.relatedNameSuggestionCandidates(
                                excluding: model.original.contactID
                            ) ?? []
                        }
                }
                .centeredRowContent()
            }
            .onDelete { offsets in
                model.edited.contactRelations.remove(atOffsets: offsets)
                model.isDirty = true
            }
            .onMove { source, destination in
                model.edited.contactRelations.move(fromOffsets: source, toOffset: destination)
                model.isDirty = true
            }
            Button {
                model.edited.contactRelations.append(
                    LabeledContactRelation(
                        label: LabelOptions.relation.first ?? "",
                        value: ContactRelation(name: "")
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add Related", systemImage: "plus.circle.fill")
            }
            .centeredRowContent()
        } header: {
            Text("Related").centeredSectionHeader()
        }
    }
}
