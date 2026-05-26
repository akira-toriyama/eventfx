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
        // CLI argv. Each standalone flag prints + exits before the
        // daemon's AX/AppKit machinery comes up.
        for arg in CommandLine.arguments.dropFirst() {
            switch arg {
            case "--help", "-h":     printHelp(); exit(0)
            case "--version", "-V":  print("eventfx \(version)"); exit(0)
            case "--validate":       exit(runValidate())
            case "--debug":          Logger.shared.debugMode = true
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
          eventfx --debug        run + log to stderr and /tmp/eventfx.log
          eventfx --validate     parse config, report status, exit
          eventfx --version      print version, exit
          eventfx --help         print this help, exit

        PATHS
          config:  \(Paths.configPath)
          log:     \(Paths.logPath)
          debug:   \(Paths.debugLogPath)  (only with --debug)

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

    static func dieUnknownFlag(_ arg: String) -> Never {
        FileHandle.standardError.write(
            Data("eventfx: unknown flag: \(arg)\n".utf8))
        FileHandle.standardError.write(
            Data("eventfx: try --help\n".utf8))
        exit(2)
    }
}
