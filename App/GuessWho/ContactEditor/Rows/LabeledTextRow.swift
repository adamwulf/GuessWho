import SwiftUI
import GuessWhoSync

struct PhoneRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        LabeledTextSection(
            title: "Phone",
            placeholder: "Phone",
            items: Binding(get: { model.edited.phoneNumbers }, set: {
                model.edited.phoneNumbers = $0
                model.isDirty = true
            }),
            labelOptions: LabelOptions.phone,
            keyboardType: .phonePad
        )
    }
}

struct EmailRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        LabeledTextSection(
            title: "Email",
            placeholder: "Email",
            items: Binding(get: { model.edited.emailAddresses }, set: {
                model.edited.emailAddresses = $0
                model.isDirty = true
            }),
            labelOptions: LabelOptions.email,
            keyboardType: .emailAddress
        )
    }
}

struct URLRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        LabeledTextSection(
            title: "URL",
            placeholder: "URL",
            items: Binding(
                get: { model.visibleURLAddresses },
                set: {
                    model.visibleURLAddresses = $0
                    model.isDirty = true
                }
            ),
            labelOptions: LabelOptions.url,
            keyboardType: .URL
        )
    }
}
