import SwiftUI
import GuessWhoSync

struct PostalAddressRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Address") {
            ForEach(model.edited.postalAddresses.indices, id: \.self) { idx in
                PostalAddressEditor(
                    entry: Binding(
                        get: { model.edited.postalAddresses[idx] },
                        set: {
                            model.edited.postalAddresses[idx] = $0
                            model.isDirty = true
                        }
                    )
                )
                .centeredRowContent()
            }
            .onDelete { offsets in
                model.edited.postalAddresses.remove(atOffsets: offsets)
                model.isDirty = true
            }
            .onMove { source, destination in
                model.edited.postalAddresses.move(fromOffsets: source, toOffset: destination)
                model.isDirty = true
            }
            Button {
                model.edited.postalAddresses.append(
                    LabeledPostalAddress(
                        label: LabelOptions.address.first ?? "",
                        value: PostalAddress()
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add Address", systemImage: "plus.circle.fill")
            }
            .centeredRowContent()
        }
    }
}

struct PostalAddressEditor: View {
    @Binding var entry: LabeledPostalAddress
    @FocusState private var focus: PostalField?

    private enum PostalField: Hashable {
        case street, city, state, postal, country
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabelPicker(
                label: Binding(
                    get: { entry.label },
                    set: { entry = LabeledPostalAddress(label: $0, value: entry.value) }
                ),
                options: LabelOptions.address
            )
            TextField("Street", text: binding(\.street))
                .focused($focus, equals: .street)
                .onSubmit { focus = .city }
            TextField("City", text: binding(\.city))
                .focused($focus, equals: .city)
                .onSubmit { focus = .state }
            TextField("State", text: binding(\.state))
                .focused($focus, equals: .state)
                .onSubmit { focus = .postal }
            TextField("Postal Code", text: binding(\.postalCode))
                .focused($focus, equals: .postal)
                .onSubmit { focus = .country }
            TextField("Country", text: binding(\.country))
                .focused($focus, equals: .country)
        }
    }

    /// Bind a writable keypath on PostalAddress while leaving the
    /// non-edited sub-fields (`subLocality`, `subAdministrativeArea`,
    /// `isoCountryCode`) untouched — carry-through preservation per
    /// docs/swiftui-contact-editor-plan.md §"Data preservation".
    private func binding(_ keyPath: WritableKeyPath<PostalAddress, String>) -> Binding<String> {
        Binding(
            get: { entry.value[keyPath: keyPath] },
            set: { newValue in
                var pa = entry.value
                pa[keyPath: keyPath] = newValue
                entry = LabeledPostalAddress(label: entry.label, value: pa)
            }
        )
    }
}
