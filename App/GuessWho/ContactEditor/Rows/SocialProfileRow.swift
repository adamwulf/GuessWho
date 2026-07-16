import SwiftUI
import GuessWhoSync

struct SocialProfileRow: View {
    @Binding var model: ContactEditModel
    var body: some View {
        Section {
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
                    // Single field for the profile identity. Username wins for
                    // display when both are stored (Contacts/iCloud derives and
                    // backfills urlString from username + service, so a record
                    // with both usually means the URL is system-generated).
                    // Editing writes whichever side the text looks like and
                    // clears the other, so a stale derived URL never survives
                    // a username change.
                    TextField("Username or URL", text: identityBinding(idx: idx))
                }
                .centeredRowContent()
            }
            .onDelete { offsets in
                model.edited.socialProfiles.remove(atOffsets: offsets)
                model.isDirty = true
            }
            .onMove { source, destination in
                model.edited.socialProfiles.move(fromOffsets: source, toOffset: destination)
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
            .centeredRowContent()
        } header: {
            Text("Social Profile").centeredSectionHeader()
        }
    }

    /// One text field backs two storage slots: URL-shaped input is saved as
    /// `urlString`, anything else as `username`. The unused slot is cleared
    /// on every edit so username stays the single source of truth for
    /// recognized services (the system re-derives the URL from it).
    private func identityBinding(idx: Int) -> Binding<String> {
        Binding(
            get: {
                let sp = model.edited.socialProfiles[idx].value
                return sp.username.isEmpty ? sp.urlString : sp.username
            },
            set: { newValue in
                let entry = model.edited.socialProfiles[idx]
                var sp = entry.value
                if Self.looksLikeURL(newValue) {
                    sp.urlString = newValue
                    sp.username = ""
                } else {
                    sp.username = newValue
                    sp.urlString = ""
                }
                model.edited.socialProfiles[idx] = LabeledSocialProfile(
                    label: entry.label,
                    value: sp
                )
                model.isDirty = true
            }
        )
    }

    /// Usernames never contain a slash or scheme; dots alone don't qualify
    /// (e.g. Instagram allows "adam.wulf"), so a bare domain typed without a
    /// path is treated as a username — acceptable for this heuristic.
    private static func looksLikeURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.contains("://") || t.hasPrefix("www.") || t.contains("/")
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
