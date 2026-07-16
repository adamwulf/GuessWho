import SwiftUI
import GuessWhoSync

struct PostalAddressRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section {
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
        } header: {
            Text("Address").centeredSectionHeader()
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
            TextField("Street", text: streetBinding)
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

    /// The street field doubles as a full-address drop zone: pasting
    /// "1 Infinite Loop, Cupertino, CA 95014" splits it into street /
    /// city / state / postal / country so the user doesn't have to.
    ///
    /// Only a multi-character jump (a paste or autofill, never keystroke
    /// typing) that parses into two or more address components triggers
    /// the split; anything else edits the street text as usual. On a
    /// split the whole address value is replaced — including hidden
    /// sub-fields like `isoCountryCode` — because a pasted full address
    /// means "this address," and mixing it with leftovers from the old
    /// one would produce a frankenaddress.
    private var streetBinding: Binding<String> {
        Binding(
            get: { entry.value.street },
            set: { newValue in
                let isBulkInsert = newValue.count > entry.value.street.count + 1
                if isBulkInsert, let parsed = PostalAddress.parse(fromFullAddress: newValue) {
                    entry = LabeledPostalAddress(label: entry.label, value: parsed)
                } else {
                    var pa = entry.value
                    pa.street = newValue
                    entry = LabeledPostalAddress(label: entry.label, value: pa)
                }
            }
        )
    }

    /// Bind a writable keypath on PostalAddress while leaving the
    /// non-edited sub-fields (`subLocality`, `subAdministrativeArea`,
    /// `isoCountryCode`) untouched, so an edit preserves data the editor
    /// doesn't surface rather than clobbering it on save.
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
