import SwiftUI
import GuessWhoSync

struct IMRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section {
            ForEach(model.edited.instantMessageAddresses.indices, id: \.self) { idx in
                VStack(alignment: .leading) {
                    // Picker drives InstantMessageAddress.service (the
                    // CN-recognized service constant). The labeled-value
                    // `label` slot stays empty; Contacts.app doesn't
                    // surface a per-row category for IM.
                    LabelPicker(
                        label: imBinding(\.service, idx: idx),
                        options: LabelOptions.imService
                    )
                    TextField("Username", text: imBinding(\.username, idx: idx))
                }
                .centeredRowContent()
            }
            .onDelete { offsets in
                model.edited.instantMessageAddresses.remove(atOffsets: offsets)
                model.isDirty = true
            }
            .onMove { source, destination in
                model.edited.instantMessageAddresses.move(fromOffsets: source, toOffset: destination)
                model.isDirty = true
            }
            Button {
                model.edited.instantMessageAddresses.append(
                    LabeledInstantMessageAddress(
                        label: "",
                        value: InstantMessageAddress(
                            username: "",
                            service: LabelOptions.imService.first ?? ""
                        )
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add IM", systemImage: "plus.circle.fill")
            }
            .centeredRowContent()
        } header: {
            Text("Instant Message").centeredSectionHeader()
        }
    }

    private func imBinding(
        _ keyPath: WritableKeyPath<InstantMessageAddress, String>,
        idx: Int
    ) -> Binding<String> {
        Binding(
            get: { model.edited.instantMessageAddresses[idx].value[keyPath: keyPath] },
            set: { newValue in
                let entry = model.edited.instantMessageAddresses[idx]
                var im = entry.value
                im[keyPath: keyPath] = newValue
                model.edited.instantMessageAddresses[idx] = LabeledInstantMessageAddress(
                    label: entry.label,
                    value: im
                )
                model.isDirty = true
            }
        )
    }
}
