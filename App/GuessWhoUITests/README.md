# GuessWhoUITests

Smoke-level XCUITest coverage for the People / Organizations / Events
tab UI. The test source is checked in but the target itself is not yet
wired into `GuessWho.xcodeproj` — adding a UI test target by hand to a
file-system-synchronized Xcode project is fiddly and risks corrupting
the project file, so the one-time wire-up is left for an Xcode session.

## One-time setup

1. Open `App/GuessWho.xcodeproj` in Xcode.
2. **File → New → Target… → iOS → UI Testing Bundle.**
3. Name it `GuessWhoUITests`; target to test = `GuessWho`; team = same as
   the app target; language = Swift.
4. Xcode creates a stub `GuessWhoUITests.swift`. Delete it — this folder
   already contains `GuessWhoUITests.swift`.
5. Drag this `App/GuessWhoUITests` folder into the new target as a
   **Reference to a folder** (so it stays synced).
6. Run with ⌘U or `xcodebuild test -scheme GuessWho`.

## Simulator preconditions

The tests assume the simulator's default address-book seed is intact
(the Anna Haro / Daniel Higgins / Kate Bell / John Appleseed contacts
that ship on every iOS Simulator runtime). If your simulator has had
its contacts wiped or migrated, expect `test_tappingPersonShowsDetailScreen`
and `test_searchClearShowsAllAgain` to fail at the name assertions —
swap the literals for a name your seed contains.

The tests also expect Contacts permission granted to
`com.milestonemade.guesswho`. The first run will prompt; from then on
the privacy DB remembers the answer for the simulator.
