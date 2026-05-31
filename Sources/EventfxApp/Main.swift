import AppKit
import EventfxAdapterMacOS
import EventfxCore
import Foundation

/// `@main enum EventfxApp` (not a top-level `main.swift`) — keeps
/// `@testable import EventfxApp` working from XCTest once tests of
/// the CLI land. Same pattern facet / chord / perch use.
@main
enum EventfxApp {
    static let version = "0.1.0"

    @MainActor
    static func main() {
        // Debug logging is env-var-triggered, not a CLI flag. run.sh's
        // foreground path exports EVENTFX_DEBUG=1; a normal/brew/raw
        // launch sets nothing and stays quiet. (Same build artifact for
        // dev and prod — inject at launch, never bake into the binary.)
        if ProcessInfo.processInfo.environment["EVENTFX_DEBUG"] != nil {
            Logger.shared.debugMode = true
        }

        // CLI argv. Each standalone flag prints + exits before the
        // daemon's AX/AppKit machinery comes up.
        for arg in CommandLine.arguments.dropFirst() {
            switch arg {
            case "--help", "-h":     printHelp(); exit(0)
            case "--version", "-V":  print("eventfx \(version)"); exit(0)
            case "--validate":       exit(runValidate())
            case "--doctor":         exit(runDoctor())
            default:                 dieUnknownFlag(arg)
            }
        }

        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted {
            Logger.shared.log(
                "accessibility NOT granted yet — grant in System Settings > "
                + "Privacy & Security > Accessibility, then restart eventfx")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let watcher = EventWatcher(config: Config())
        watcher.start()
        app.run()
    }

    static func printHelp() {
        print("""
        eventfx \(version) — macOS event-broker daemon
        Dispatches configured commands on AX events (window focus, text selection).

        USAGE
          eventfx                run as daemon (default)
          eventfx --validate     parse config, report count, exit
          eventfx --doctor       self-check (AX / config / daemon / log), exit
          eventfx --version      print version, exit
          eventfx --help         print this help, exit

        PATHS
          config:  \(Paths.configPath)
          log:     \(Paths.logPath)
          debug:   \(Paths.debugLogPath)  (only with EVENTFX_DEBUG set)

        See: https://github.com/akira-toriyama/eventfx
        """)
    }

    static func runValidate() -> Int32 {
        let exists = FileManager.default.fileExists(atPath: Paths.configPath)
        let cfg = Config()
        cfg.reloadIfChanged()
        print("config: \(Paths.configPath)\(exists ? "" : " (missing)")")
        print("commands: \(cfg.commands.count)")
        return 0
    }

    /// Self-check for "なんで動かない?" の最短切り分け。家風 (chord /
    /// perch) の `--doctor` に揃える。CLI 起動なので daemon の AX 状態と
    /// ロード状態を別々に見られる (`AXIsProcessTrusted()` は呼んだ
    /// プロセスについて答えるため、ここでの結果は **CLI バイナリの**
    /// 許可状態。daemon と CLI が同じ binary なら一致する)。
    static func runDoctor() -> Int32 {
        var issues = 0

        // 1) Accessibility 権限。daemon が AX 通知を購読するのに必要。
        if AXIsProcessTrusted() {
            print("✓ Accessibility: granted")
        } else {
            print("✗ Accessibility: NOT granted — grant the eventfx binary "
                + "in System Settings > Privacy & Security > Accessibility")
            issues += 1
        }

        // 2) Config。存在しない場合 daemon が起動時に example を生成するが、
        //    --doctor 単体ではそのトリガに到達しないので警告だけ。
        let cfgPath = Paths.configPath
        if FileManager.default.fileExists(atPath: cfgPath) {
            let cfg = Config()
            cfg.reloadIfChanged()
            let n = cfg.commands.count
            if n > 0 {
                print("✓ Config: \(cfgPath) (\(n) command(s))")
            } else {
                print("⚠ Config: \(cfgPath) (0 commands — nothing will run)")
            }
        } else {
            print("⚠ Config: \(cfgPath) missing — will be auto-created on "
                + "next daemon start")
        }

        // 3) Log file。daemon が動いていれば追記され続けるはず。
        let logPath = Paths.logPath
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int,
           let mtime = attrs[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(mtime)
            let ageStr: String
            if age < 60 { ageStr = String(format: "%.0fs ago", age) }
            else if age < 3600 { ageStr = String(format: "%.0fm ago", age/60) }
            else { ageStr = String(format: "%.1fh ago", age/3600) }
            print("✓ Log: \(logPath) (\(size) bytes, last write \(ageStr))")
        } else {
            print("⚠ Log: \(logPath) not yet created")
        }

        // 4) Daemon ロード状態。`launchctl list <label>` を叩いて exit 0 か
        //    どうかだけ見る。家風 install (com.local.eventfx) を主、
        //    brew install (homebrew.mxcl.eventfx) を副で確認。
        let labels = ["com.local.eventfx", "homebrew.mxcl.eventfx"]
        var foundLabel: String?
        for label in labels {
            if launchctlListed(label) { foundLabel = label; break }
        }
        if let label = foundLabel {
            print("✓ Daemon: \(label) loaded")
        } else {
            print("✗ Daemon: not loaded — run ./install.sh (source) or "
                + "`brew services start eventfx` (Homebrew)")
            issues += 1
        }

        // 5) 持続署名の有無。`.signing-id` ファイルを目印にする
        //    (./setup-signing-cert.sh の出力)。ファイルが repo root に
        //    あるかは CWD 依存なので、家風メッセージだけ案内。
        // 注: 本物の codesign identifier 検証はやらない (Process で
        //     codesign を呼ぶより、--doctor のスコープを狭く保ちたい)。

        let verdict = issues == 0
            ? "doctor: all checks passed"
            : "doctor: \(issues) issue(s) — see ✗ above"
        print(verdict)
        return issues == 0 ? 0 : 1
    }

    /// `launchctl list <label>` が exit 0 を返すか。プロセス起動の
    /// オーバーヘッドはあるが --doctor は対話実行なので問題ない。
    private static func launchctlListed(_ label: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list", label]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func dieUnknownFlag(_ arg: String) -> Never {
        FileHandle.standardError.write(
            Data("eventfx: unknown flag: \(arg)\n".utf8))
        FileHandle.standardError.write(
            Data("eventfx: try --help\n".utf8))
        exit(2)
    }
}
