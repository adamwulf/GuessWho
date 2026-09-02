import Foundation
import Testing
@testable import GuessWhoSync

@Suite("DepartmentFavoriteKey")
struct DepartmentFavoriteKeyTests {
    private static let orgUUID = "11111111-2222-4333-8444-555566667777"

    @Test
    func encodesUUIDSlashDepartmentAndRoundTrips() throws {
        let key = DepartmentFavoriteKey(organizationGuessWhoID: Self.orgUUID, department: "Lilie")
        #expect(key.favoriteID == "\(Self.orgUUID)/Lilie")

        let parsed = try #require(DepartmentFavoriteKey(favoriteID: key.favoriteID))
        #expect(parsed.organizationGuessWhoID == Self.orgUUID)
        #expect(parsed.department == "Lilie")
    }

    @Test
    func lowercasesTheOrganizationUUIDButKeepsDepartmentCase() throws {
        let key = DepartmentFavoriteKey(
            organizationGuessWhoID: Self.orgUUID.uppercased(), department: "Lilie")
        #expect(key.organizationGuessWhoID == Self.orgUUID)
        #expect(key.department == "Lilie")
        #expect(key.favoriteID == "\(Self.orgUUID)/Lilie")
    }

    @Test
    func trimsSurroundingWhitespaceFromTheDepartment() {
        let key = DepartmentFavoriteKey(
            organizationGuessWhoID: Self.orgUUID, department: "  Lilie  ")
        #expect(key.department == "Lilie")
        #expect(key.favoriteID == "\(Self.orgUUID)/Lilie")
    }

    @Test
    func aDepartmentNameContainingASlashRoundTrips() throws {
        // The key is parsed by the fixed 36-char prefix, never by searching for
        // the separator, so an internal "/" survives intact.
        let key = DepartmentFavoriteKey(
            organizationGuessWhoID: Self.orgUUID, department: "R&D / AI")
        #expect(key.favoriteID == "\(Self.orgUUID)/R&D / AI")

        let parsed = try #require(DepartmentFavoriteKey(favoriteID: key.favoriteID))
        #expect(parsed.organizationGuessWhoID == Self.orgUUID)
        #expect(parsed.department == "R&D / AI")
    }

    @Test
    func parseRejectsMalformedIDs() {
        // Not a UUID prefix.
        #expect(DepartmentFavoriteKey(favoriteID: "not-a-uuid/Lilie") == nil)
        // A bare UUID with no department part.
        #expect(DepartmentFavoriteKey(favoriteID: Self.orgUUID) == nil)
        // A UUID followed by "/" but a blank department.
        #expect(DepartmentFavoriteKey(favoriteID: "\(Self.orgUUID)/") == nil)
        #expect(DepartmentFavoriteKey(favoriteID: "\(Self.orgUUID)/   ") == nil)
        // The 37th character must be the "/" separator, not another character.
        #expect(DepartmentFavoriteKey(favoriteID: "\(Self.orgUUID)-Lilie") == nil)
        // Empty string.
        #expect(DepartmentFavoriteKey(favoriteID: "") == nil)
    }

    @Test
    func matchesIsTrimmedAndCaseInsensitive() {
        let key = DepartmentFavoriteKey(organizationGuessWhoID: Self.orgUUID, department: "Lilie")
        #expect(key.matches(department: "lilie"))
        #expect(key.matches(department: "  LILIE  "))
        #expect(key.matches(department: "Lilie"))
        #expect(!key.matches(department: "Sales"))
    }

    @Test
    func aLowercasedStoredIDStillParsesAndMatchesTheOriginalCase() throws {
        // The store lowercases the whole id on write; the department comes back
        // lowercased but still matches the live display form case-insensitively.
        let stored = DepartmentFavoriteKey(
            organizationGuessWhoID: Self.orgUUID, department: "Lilie").favoriteID.lowercased()
        let parsed = try #require(DepartmentFavoriteKey(favoriteID: stored))
        #expect(parsed.department == "lilie")
        #expect(parsed.matches(department: "Lilie"))
    }
}
