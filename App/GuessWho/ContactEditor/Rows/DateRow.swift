import SwiftUI
import GuessWhoSync

struct DateRow: View {
    @Binding var model: ContactEditModel

    var body: some View {
        Section {
            ForEach(model.edited.dates.indices, id: \.self) { idx in
                DateRowEntry(
                    entry: Binding(
                        get: { model.edited.dates[idx] },
                        set: {
                            model.edited.dates[idx] = $0
                            model.isDirty = true
                        }
                    )
                )
                .centeredRowContent()
            }
            .onDelete { offsets in
                model.edited.dates.remove(atOffsets: offsets)
                model.isDirty = true
            }
            .onMove { source, destination in
                model.edited.dates.move(fromOffsets: source, toOffset: destination)
                model.isDirty = true
            }
            Button {
                // New entries default to with-year (today's date).
                let dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                model.edited.dates.append(
                    LabeledDate(label: LabelOptions.date.first ?? "", value: dc)
                )
                model.isDirty = true
            } label: {
                Label("Add Date", systemImage: "plus.circle.fill")
            }
            .centeredRowContent()
        } header: {
            Text("Dates").centeredSectionHeader()
        }
    }
}

/// One row in the Dates section. Owns its own `hasYear` derivation:
/// the value is true iff the underlying `DateComponents.year` is non-nil.
/// This mirrors `BirthdayRow`'s hasYear semantics so anniversaries with
/// no year (which Contacts.app supports) round-trip through the editor
/// unchanged.
private struct DateRowEntry: View {
    @Binding var entry: LabeledDate

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                LabelPicker(
                    label: Binding(
                        get: { entry.label },
                        set: { entry = LabeledDate(label: $0, value: entry.value) }
                    ),
                    options: LabelOptions.date
                )
                DatePicker(
                    "Date",
                    selection: Binding(
                        get: { dateForPicker() },
                        set: { writeBack(from: $0) }
                    ),
                    displayedComponents: [.date]
                )
                .labelsHidden()
            }
            Toggle("Include year", isOn: Binding(
                get: { hasYear },
                set: { newValue in
                    let prev = hasYear
                    guard prev != newValue else { return }
                    if newValue {
                        // false → true: stamp the sentinel year so the
                        // entry has a year on save. The user can edit
                        // the year via the DatePicker afterward.
                        var dc = entry.value
                        dc.year = ContactEditModel.birthdaySentinelYear
                        entry = LabeledDate(label: entry.label, value: dc)
                    } else {
                        // true → false: strip the year, preserving
                        // month/day exactly as the user has them.
                        var dc = DateComponents()
                        dc.month = entry.value.month
                        dc.day = entry.value.day
                        entry = LabeledDate(label: entry.label, value: dc)
                    }
                }
            ))
        }
    }

    /// Whether the entry currently has a year component.
    private var hasYear: Bool { entry.value.year != nil }

    /// Materialize a `Date` for the picker, substituting the sentinel
    /// year when no year is present so the picker has a valid input.
    private func dateForPicker() -> Date {
        var dc = entry.value
        if dc.year == nil {
            dc.year = ContactEditModel.birthdaySentinelYear
        }
        return Calendar.current.date(from: dc) ?? Date()
    }

    /// Write the picker's Date back, preserving the hasYear shape.
    private func writeBack(from date: Date) {
        let cal = Calendar.current
        let dc = cal.dateComponents([.year, .month, .day], from: date)
        var write = DateComponents()
        write.month = dc.month
        write.day = dc.day
        if hasYear {
            write.year = dc.year
        }
        entry = LabeledDate(label: entry.label, value: write)
    }
}
