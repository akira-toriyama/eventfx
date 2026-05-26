import Foundation

/// Append-only logger with two outputs:
/// - `Paths.logPath` (always, production)
/// - stderr + `Paths.debugLogPath` (only when `debugMode == true`)
///
/// `debugMode` is set by the App layer from `--debug`. Centralising
/// the flag here means call sites just say `Logger.shared.log(...)`
/// without threading the option through every layer.
public final class Logger: @unchecked Sendable {
    // @unchecked Sendable: ロガーは main-thread + AX 経由のシリアル発火が
    // 想定で、debugMode は起動時 (CLI 解析) に 1 度だけ書かれる。Swift 6
    // strict concurrency をパスさせるための表明であって、ロックは置かない。
    public static let shared = Logger()
    public var debugMode = false

    private init() {}

    public func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }

        let dir = (Paths.logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        Logger.append(data, to: Paths.logPath)

        // --debug: surface to stderr (so foreground ./run.sh streams
        // events) and tee to a tmp log that's easy to `tail -f`
        // independently of the production log path.
        if debugMode {
            FileHandle.standardError.write(data)
            Logger.append(data, to: Paths.debugLogPath)
        }
    }

    private static func append(_ data: Data, to path: String) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
