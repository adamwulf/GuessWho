import SwiftUI
import GuessWhoSync

struct BirthdayRow: View {
    @Binding var model: ContactEditModel

    var body: some View {
        Section("Birthday") {
            if model.edited.birthday != nil {
                // SwiftUI's DatePicker only exposes the `.date` component
                // (no month/day-only variant). When `birthdayHasYear` is
                // false, the picker still shows the year wheel populated
                // with the sentinel year (2000); the data layer strips it
                // on save via ContactEditModel.setBirthday. The "Include
                // year" toggle is the user-visible control for the
                // year-vs-no-year intent — see the comment on the toggle.
                DatePicker(
                    "Birthday",
                    selection: Binding(
                        get: { model.birthdayAsDate() ?? Date() },
                        set: { model.setBirthday(from: $0) }
                    ),
                    displayedComponents: [.date]
                )
                .labelsHidden()
                // When "Include year" is off, the year shown above is
                // a sentinel (2000) and is dropped on save. The toggle
                // is how the user signals intent; the picker itself
                // can't hide its year wheel.
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
                Button(role: .destructive) {
                    model.clearBirthday()
                } label: {
                    Label("Remove Birthday", systemImage: "minus.circle")
                }
            } else {
                Button {
                    let dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                    model.edited.birthday = dc
                    model.birthdayHasYear = (dc.year != nil)
                    model.isDirty = true
                } label: {
                    Label("Add Birthday", systemImage: "plus.circle.fill")
                }
            }
        }
    }
}
