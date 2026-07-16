import SwiftUI
import GuessWhoSync

struct BirthdayRow: View {
    @Binding var model: ContactEditModel

    var body: some View {
        Section {
            if model.edited.birthday != nil {
                // SwiftUI's DatePicker only exposes the `.date` component
                // (no month/day-only variant). When `birthdayHasYear` is
                // false, the picker still shows the year wheel populated
                // with the sentinel year (2000); the data layer strips it
                // on save via ContactEditModel.setBirthday. The "Include
                // year" toggle below is the user-visible control for the
                // year-vs-no-year intent.
                DatePicker(
                    "Birthday",
                    selection: Binding(
                        get: { model.birthdayAsDate() ?? Date() },
                        set: { model.setBirthday(from: $0) }
                    ),
                    displayedComponents: [.date]
                )
                .labelsHidden()
                .centeredRowContent()
                // How the user signals year-vs-no-year intent (the picker
                // can't hide its year wheel; see the DatePicker above).
                Toggle("Include year", isOn: Binding(
                    get: { model.birthdayHasYear },
                    set: { newValue in
                        let prev = model.birthdayHasYear
                        model.birthdayHasYear = newValue
                        if prev != newValue, let d = model.birthdayAsDate() {
                            model.setBirthday(from: d)
                        }
                    }
                ))
                .centeredRowContent()
                Button(role: .destructive) {
                    model.clearBirthday()
                } label: {
                    Label("Remove Birthday", systemImage: "minus.circle")
                }
                .centeredRowContent()
            } else {
                Button {
                    let dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                    model.edited.birthday = dc
                    model.birthdayHasYear = (dc.year != nil)
                    model.isDirty = true
                } label: {
                    Label("Add Birthday", systemImage: "plus.circle.fill")
                }
                .centeredRowContent()
            }
        } header: {
            Text("Birthday").centeredSectionHeader()
        }
    }
}
