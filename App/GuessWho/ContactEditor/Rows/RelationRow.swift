import SwiftUI
import GuessWhoSync

struct RelationsSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Related") {
            ForEach(model.edited.contactRelations.indices, id: \.self) { idx in
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
                    TextField("Name", text: Binding(
                        get: { model.edited.contactRelations[idx].value.name },
                        set: {
                            model.edited.contactRelations[idx] = LabeledContactRelation(
                                label: model.edited.contactRelations[idx].label,
                                value: ContactRelation(name: $0)
                            )
                            model.isDirty = true
                        }
                    ))
                }
            }
            .onDelete { offsets in
                model.edited.contactRelations.remove(atOffsets: offsets)
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
        }
    }
}
