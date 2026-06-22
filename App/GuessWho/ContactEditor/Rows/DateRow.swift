import SwiftUI
import GuessWhoSync

struct DatesSection: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Dates") {
            ForEach(model.edited.dates.indices, id: \.self) { idx in
                HStack {
                    LabelPicker(
                        label: Binding(
                            get: { model.edited.dates[idx].label },
                            set: {
                                model.edited.dates[idx] = LabeledDate(
                                    label: $0,
                                    value: model.edited.dates[idx].value
                                )
                                model.isDirty = true
                            }
                        ),
                        options: LabelOptions.date
                    )
                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: {
                                Calendar.current.date(from: model.edited.dates[idx].value)
                                    ?? Date()
                            },
                            set: { newDate in
                                let dc = Calendar.current.dateComponents(
                                    [.year, .month, .day],
                                    from: newDate
                                )
                                model.edited.dates[idx] = LabeledDate(
                                    label: model.edited.dates[idx].label,
                                    value: dc
                                )
                                model.isDirty = true
                            }
                        ),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }
            }
            .onDelete { offsets in
                model.edited.dates.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                let dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                model.edited.dates.append(
                    LabeledDate(label: LabelOptions.date.first ?? "", value: dc)
                )
                model.isDirty = true
            } label: {
                Label("Add Date", systemImage: "plus.circle.fill")
            }
        }
    }
}
