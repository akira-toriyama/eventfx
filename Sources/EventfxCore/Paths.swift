import Foundation

/// Path constants for eventfx state and config. Resolved once at
/// process start from `$HOME` + `$XDG_CONFIG_HOME` (with the usual
/// XDG fallback). Pure Foundation — safe to use from anywhere.
public enum Paths {
    public static let home = NSHomeDirectory()
    public static let configDir =
        envOr("XDG_CONFIG_HOME", home + "/.config") + "/eventfx"
    public static let configPath = configDir + "/config"
    public static let logPath = home + "/.local/state/eventfx.log"
    public static let debugLogPath = "/tmp/eventfx.log"
}

/// `$KEY` if set and non-empty, else `fallback`. Used to honor
/// XDG-style overrides without disturbing existing env vars.
public func envOr(_ key: String, _ fallback: String) -> String {
    if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty {
        return v
    }
    return fallback
}
