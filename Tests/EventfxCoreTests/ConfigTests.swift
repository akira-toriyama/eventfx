import XCTest
@testable import EventfxCore

final class ConfigTests: XCTestCase {

    // MARK: parseCommands

    func testEmptyText() {
        XCTAssertEqual(Config.parseCommands(""), [])
    }

    func testSingleCommand() {
        XCTAssertEqual(Config.parseCommands("echo hi"), ["echo hi"])
    }

    func testCommentsAreDropped() {
        let text = """
        # comment
        echo a
        # another
        echo b
        """
        XCTAssertEqual(Config.parseCommands(text), ["echo a", "echo b"])
    }

    func testEmptyAndWhitespaceLinesDropped() {
        let text = "echo a\n\n   \necho b\n"
        XCTAssertEqual(Config.parseCommands(text), ["echo a", "echo b"])
    }

    func testSurroundingWhitespaceTrimmed() {
        let text = "   echo a   \n\t echo b \t"
        XCTAssertEqual(Config.parseCommands(text), ["echo a", "echo b"])
    }

    func testBackslashContinuationIsNotJoined() {
        // Documented gotcha: eventfx splits on \n BEFORE handing to sh,
        // so backslash line continuation in the config file doesn't work.
        // Each physical line becomes an independent command. Test pins
        // the current behavior so a refactor can't silently change it.
        let text = "[ x ] && \\\n  echo b"
        XCTAssertEqual(Config.parseCommands(text), ["[ x ] && \\", "echo b"])
    }

    func testHashOnlyAfterTrimIsComment() {
        XCTAssertEqual(Config.parseCommands("  # leading whitespace ok"), [])
    }

    func testCommandWithHashLater() {
        // Only leading-# counts as a comment line. A command with a #
        // later in the string is a valid command (shell will handle).
        let text = "echo hi # this is shell comment, not eventfx's"
        XCTAssertEqual(Config.parseCommands(text),
                       ["echo hi # this is shell comment, not eventfx's"])
    }

    // MARK: bootstrapExampleIfMissing + reloadIfChanged

    func testBootstrapWritesWhenMissing() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let cfg = Config(path: path)
        cfg.bootstrapExampleIfMissing("# hello\necho one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        cfg.reloadIfChanged()
        XCTAssertEqual(cfg.commands, ["echo one"])
    }

    func testBootstrapDoesNotOverwriteExisting() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "echo original".write(toFile: path,
                                  atomically: true, encoding: .utf8)
        let cfg = Config(path: path)
        cfg.bootstrapExampleIfMissing("echo overwritten")
        cfg.reloadIfChanged()
        XCTAssertEqual(cfg.commands, ["echo original"])
    }

    func testReloadDetectsMtimeChange() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "echo v1".write(toFile: path,
                            atomically: true, encoding: .utf8)
        let cfg = Config(path: path)
        cfg.reloadIfChanged()
        XCTAssertEqual(cfg.commands, ["echo v1"])

        // Make the mtime move forward (HFS+/APFS can have 1-second
        // resolution depending on the volume — set it explicitly so
        // the test isn't flaky on fast systems).
        try "echo v2".write(toFile: path,
                            atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: path)
        cfg.reloadIfChanged()
        XCTAssertEqual(cfg.commands, ["echo v2"])
    }

    func testReloadHandlesMissingFile() {
        let path = tempPath()  // not created
        let cfg = Config(path: path)
        cfg.reloadIfChanged()  // should not throw / crash
        XCTAssertEqual(cfg.commands, [])
    }

    // MARK: helpers

    private func tempPath() -> String {
        let dir = NSTemporaryDirectory()
        return dir + "eventfx-cfgtest-\(UUID().uuidString)"
    }
}
