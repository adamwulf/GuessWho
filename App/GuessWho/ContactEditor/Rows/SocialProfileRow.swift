import SwiftUI
import GuessWhoSync

struct SocialProfileRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section("Social Profile") {
            ForEach(model.edited.socialProfiles.indices, id: \.self) { idx in
                VStack(alignment: .leading) {
                    // Picker drives SocialProfile.service (the CN-recognized
                    // service constant: CNSocialProfileServiceTwitter, etc).
                    // The labeled-value `label` slot stays empty by default
                    // — CN doesn't surface a per-profile category in
                    // Contacts.app for social profiles.
                    LabelPicker(
                        label: socialBinding(\.service, idx: idx),
                        options: LabelOptions.socialService
                    )
                    TextField("Username", text: socialBinding(\.username, idx: idx))
                    TextField("URL", text: socialBinding(\.urlString, idx: idx))
                }
            }
            .onDelete { offsets in
                model.edited.socialProfiles.remove(atOffsets: offsets)
                model.isDirty = true
            }
            Button {
                model.edited.socialProfiles.append(
                    LabeledSocialProfile(
                        label: "",
                        value: SocialProfile(
                            urlString: "",
                            username: "",
                            userIdentifier: "",
                            service: LabelOptions.socialService.first ?? ""
                        )
                    )
                )
                model.isDirty = true
            } label: {
                Label("Add Social Profile", systemImage: "plus.circle.fill")
            }
        }
    }

    private func socialBinding(
        _ keyPath: WritableKeyPath<SocialProfile, String>,
        idx: Int
    ) -> Binding<String> {
        Binding(
            get: { model.edited.socialProfiles[idx].value[keyPath: keyPath] },
            set: { newValue in
                let entry = model.edited.socialProfiles[idx]
                var sp = entry.value
                sp[keyPath: keyPath] = newValue
                model.edited.socialProfiles[idx] = LabeledSocialProfile(
                    label: entry.label,
                    value: sp
                )
                model.isDirty = true
            }
        )
    }
}
