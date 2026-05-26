import Foundation

/// Shell-command config with mtime-driven lazy hot reload.
///
/// Public surface is intentionally small: `commands` (the parsed
/// list, refreshed by the most recent reloadIfChanged), and the
/// reload trigger itself. Each line in the file is exposed verbatim
/// — eventfx hands it to `/bin/sh -c` unchanged.
public final class Config {
    public private(set) var commands: [String] = []
    private var mtime: Date?
    private let path: String

    public init(path: String = Paths.configPath) {
        self.path = path
    }

    /// Write the bundled example to `path` only if no file exists
    /// there. Idempotent — subsequent runs are a no-op even if the
    /// user edited the example.
    public func bootstrapExampleIfMissing(_ template: String = exampleConfig) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? template.write(toFile: path, atomically: true, encoding: .utf8)
        Logger.shared.log("created example config: \(path)")
    }

    /// Re-read the config file iff its mtime has advanced since the
    /// last call. Cheap to invoke on every event fire — the stat
    /// is one syscall and the parse only runs on actual changes.
    public func reloadIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let m = attrs?[.modificationDate] as? Date else {
            if !commands.isEmpty || mtime != nil {
                commands = []
                mtime = nil
                Logger.shared.log("config missing -> 0 commands")
            }
            return
        }
        if m == mtime { return }
        mtime = m
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        commands = Config.parseCommands(text)
        Logger.shared.log("config loaded: \(commands.count) command(s)")
    }

    /// Parse the raw config text into the command list. Public + pure
    /// (no I/O, no logging) so unit tests can exercise the parser
    /// directly without a temp file.
    ///
    /// Rules: split on `\n`, strip surrounding whitespace, drop empty
    /// and `#`-prefixed lines. Each surviving line is one command.
    public static func parseCommands(_ text: String) -> [String] {
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
