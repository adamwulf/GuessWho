import XCTest
@testable import GuessWhoMCPCore

/// Validates the four states of `CLISymlinkResolver.resolve()` against
/// filesystem fixtures created in a per-test temp directory (mirrors Muse's
/// shipped test suite). Production callers resolve /usr/local/bin/guesswho
/// against the bundle's guesswho-cli path; these tests use the
/// path-injecting variant so we never need write access to /usr/local/bin.
final class CLISymlinkResolverTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLISymlinkResolverTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmpDir = dir
    }

    override func tearDown() {
        if let tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        tmpDir = nil
        super.tearDown()
    }

    private func tempPath(_ name: String) -> String {
        tmpDir.appendingPathComponent(name).path
    }

    private func writeRegularFile(_ path: String, content: String = "") {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func symlink(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: path),
            withDestinationURL: URL(fileURLWithPath: destination))
    }

    // MARK: - State coverage

    func test_resolve_notInstalled_whenNothingExistsAtPath() {
        let path = tempPath("guesswho")
        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: nil)
        XCTAssertEqual(status.state, .notInstalled)
        XCTAssertNil(status.target)
        XCTAssertEqual(status.symlinkPath, path)
    }

    func test_resolve_installed_whenSymlinkPointsAtExpectedTarget() throws {
        let path = tempPath("guesswho")
        let target = tempPath("guesswho-cli")
        writeRegularFile(target, content: "binary")
        try symlink(path, to: target)

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: target)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.target, target)
        XCTAssertEqual(status.symlinkPath, path)
    }

    func test_resolve_dangling_whenSymlinkTargetMissing() throws {
        let path = tempPath("guesswho")
        let target = tempPath("does-not-exist")
        try symlink(path, to: target)

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: target)
        XCTAssertEqual(status.state, .dangling)
        XCTAssertEqual(status.target, target)
    }

    func test_resolve_conflictingFile_whenRegularFileOccupiesPath() {
        let path = tempPath("guesswho")
        writeRegularFile(path, content: "i'm not a symlink")

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: nil)
        XCTAssertEqual(status.state, .conflictingFile)
        XCTAssertEqual(status.target, path)
        XCTAssertEqual(status.symlinkPath, path)
    }

    /// The wrong-channel / multi-install trap: a symlink pointing at a
    /// DIFFERENT (older / other-channel) bundle is a conflict, never
    /// `installed`.
    func test_resolve_conflictingFile_whenSymlinkPointsElsewhere() throws {
        let path = tempPath("guesswho")
        let alien = tempPath("some-other-binary")
        writeRegularFile(alien, content: "not us")
        try symlink(path, to: alien)

        let expected = tempPath("guesswho-cli")
        writeRegularFile(expected, content: "we'd want this")

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: expected)
        XCTAssertEqual(status.state, .conflictingFile)
        XCTAssertEqual(status.target, alien)
    }

    /// When `expectedTargetPath` is nil (test-only path), any non-dangling
    /// symlink is treated as `.installed` regardless of where it points.
    /// Production callers always pass the bundle path.
    func test_resolve_installed_whenExpectedTargetPathIsNil() throws {
        let path = tempPath("guesswho")
        let alien = tempPath("alien")
        writeRegularFile(alien, content: "anyone")
        try symlink(path, to: alien)

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: nil)
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.target, alien)
    }

    // MARK: - resolvingSymlinksInPath on BOTH sides (the Setapp/Sparkle case)

    /// Bundle paths on symlink-shipping channels contain symlinks
    /// themselves. The symlink's destination and the expected target are
    /// DIFFERENT literal strings that resolve to the same file — a raw
    /// string compare would false-negative this legit install.
    func test_resolve_installed_whenBothSidesResolveToSameFile() throws {
        let realDir = tempPath("Versions/A")
        let realTarget = realDir + "/guesswho-cli"
        writeRegularFile(realTarget, content: "binary")
        // "Current" → "A", so <tmp>/Versions/Current/guesswho-cli is a
        // symlink-containing alias of the real path.
        try symlink(tempPath("Versions/Current"), to: realDir)
        let aliasedTarget = tempPath("Versions/Current") + "/guesswho-cli"

        // The installed link names the ALIASED path; the app expects the
        // REAL path (or vice versa — same comparison either way).
        let path = tempPath("guesswho")
        try symlink(path, to: aliasedTarget)

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: realTarget)
        XCTAssertEqual(status.state, .installed)
    }

    /// Same fixture, but the expected side is the symlink-containing path.
    func test_resolve_installed_whenExpectedPathContainsSymlinks() throws {
        let realDir = tempPath("Versions/A")
        let realTarget = realDir + "/guesswho-cli"
        writeRegularFile(realTarget, content: "binary")
        try symlink(tempPath("Versions/Current"), to: realDir)
        let aliasedExpected = tempPath("Versions/Current") + "/guesswho-cli"

        let path = tempPath("guesswho")
        try symlink(path, to: realTarget)

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: aliasedExpected)
        XCTAssertEqual(status.state, .installed)
    }

    /// A relative symlink destination must be resolved against the
    /// symlink's own directory, not the process's working directory.
    func test_resolve_installed_whenSymlinkDestinationIsRelative() throws {
        let target = tempPath("guesswho-cli")
        writeRegularFile(target, content: "binary")
        let path = tempPath("guesswho")
        try FileManager.default.createSymbolicLink(
            atPath: path, withDestinationPath: "guesswho-cli")

        let status = CLISymlinkResolver.resolve(symlinkPath: path, expectedTargetPath: target)
        XCTAssertEqual(status.state, .installed)
    }

    // MARK: - Removal command

    func test_removalCommand_quotesThePath() {
        XCTAssertEqual(
            CLISymlinkResolver.removalCommand(),
            "rm '/usr/local/bin/guesswho'")
        XCTAssertEqual(
            CLISymlinkResolver.removalCommand(symlinkPath: "/tmp/it's here/guesswho"),
            "rm '/tmp/it'\\''s here/guesswho'")
    }
}
