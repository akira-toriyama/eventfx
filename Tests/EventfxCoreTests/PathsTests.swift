import XCTest
@testable import EventfxCore

final class PathsTests: XCTestCase {

    // MARK: envOr

    func testEnvOrReturnsFallbackWhenUnset() {
        let key = "EVENTFX_TEST_UNSET_\(UUID().uuidString)"
        // Sanity: the random key truly is unset.
        XCTAssertNil(ProcessInfo.processInfo.environment[key])
        XCTAssertEqual(envOr(key, "fb"), "fb")
    }

    func testEnvOrReturnsValueWhenSet() {
        let key = "EVENTFX_TEST_SET_\(UUID().uuidString)"
        setenv(key, "actual", 1)
        defer { unsetenv(key) }
        XCTAssertEqual(envOr(key, "fb"), "actual")
    }

    func testEnvOrTreatsEmptyAsUnset() {
        // Documented behaviour: empty-string env vars are treated as
        // unset, mirroring `${VAR:-default}` shell semantics. This is
        // the difference between envOr and a plain dict lookup, and
        // exactly what XDG fallback in Paths.configDir depends on.
        let key = "EVENTFX_TEST_EMPTY_\(UUID().uuidString)"
        setenv(key, "", 1)
        defer { unsetenv(key) }
        XCTAssertEqual(envOr(key, "fb"), "fb")
    }

    // MARK: Paths constants

    func testPathsConfigDirEndsWithEventfx() {
        // The XDG fallback is read once at module load, so we can't
        // override XDG_CONFIG_HOME from here to verify the fallback
        // branch. Pin the structural invariant instead: the dir
        // always ends in `/eventfx`.
        XCTAssertTrue(Paths.configDir.hasSuffix("/eventfx"),
                      "got: \(Paths.configDir)")
    }

    func testPathsConfigPathIsConfigDirSlashConfig() {
        XCTAssertEqual(Paths.configPath, Paths.configDir + "/config")
    }

    func testPathsLogPathUnderLocalState() {
        XCTAssertTrue(Paths.logPath.hasSuffix("/.local/state/eventfx.log"),
                      "got: \(Paths.logPath)")
    }

    func testPathsDebugLogPathIsTmp() {
        XCTAssertEqual(Paths.debugLogPath, "/tmp/eventfx.log")
    }
}
