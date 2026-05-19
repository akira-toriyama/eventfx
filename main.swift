// focusfx
//
// アクティブ（フォーカス）ウィンドウが変わったら、設定された任意コマンドを
// 実行する macOS 常駐デーモン。効果音・枠強調 等は「設定（コマンド文字列）」
// 側の責務で、このバイナリは検知とディスパッチしか知らない（ゼロハードコード）。
//
// 検知: ポーリングしない（AX イベント駆動）。
//   - NSWorkspace.didActivateApplication で最前面アプリ切替を受け、
//   - 最前面アプリの AXUIElement に kAXFocusedWindowChanged /
//     kAXMainWindowChanged の AX オブザーバを張替え（最前面1つだけ＝軽量）。
//   - フォーカス窓の CGWindowID が直前と変われば window_focused を発火。
//
// 設定: ${XDG_CONFIG_HOME:-$HOME/.config}/focusfx/config
//   1行＝1コマンド（/bin/sh -c で実行）。空行と # 行は無視。保存で hot reload
//   （次の発火時に mtime を見て遅延再読込＝タイマー無し）。
//   各コマンドへ context を環境変数で注入:
//     FOCUSFX_EVENT / FOCUSFX_WINDOW_ID / FOCUSFX_PID / FOCUSFX_APP /
//     FOCUSFX_TITLE
//
// 要 Accessibility 権限（初回プロンプト。LaunchAgent のバイナリを
// システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可）。

import Cocoa
import ApplicationServices

// AXUIElement から CGWindowID を取る非公開関数（長年実績のある安定 API）。
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

func envOr(_ key: String, _ fallback: String) -> String {
    if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
    return fallback
}

let home = NSHomeDirectory()
let configDir = envOr("XDG_CONFIG_HOME", home + "/.config") + "/focusfx"
let configPath = configDir + "/config"
let logPath = home + "/.local/state/focusfx.log"

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let dir = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir,
                                             withIntermediateDirectories: true)
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        try? fh.close()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

let exampleConfig = """
# focusfx — アクティブ（フォーカス）ウィンドウが変わるたびに
# 以下のコマンドを /bin/sh -c で実行する。1行＝1コマンド。# はコメント。
# 保存すれば自動反映（hot reload・デーモン再起動不要）。
#
# 利用できる環境変数:
#   $FOCUSFX_EVENT      \"window_focused\"
#   $FOCUSFX_WINDOW_ID  フォーカス窓の CGWindowID
#   $FOCUSFX_PID        アプリの PID
#   $FOCUSFX_APP        アプリ名
#   $FOCUSFX_TITLE      ウィンドウタイトル

# 効果音
afplay "${XDG_DATA_HOME:-$HOME/.local/share}/sounds/window_focused.wav"

# 枠を一瞬強調する（JankyBorders 併用時の例）
# borders width=10 ; sleep 1 ; borders width=6
"""

/// 設定（コマンド列）。mtime キャッシュで「発火時だけ」遅延再読込。
final class Config {
    private(set) var commands: [String] = []
    private var mtime: Date?

    func bootstrapExampleIfMissing() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }
        try? FileManager.default.createDirectory(atPath: configDir,
                                                 withIntermediateDirectories: true)
        try? exampleConfig.write(toFile: configPath, atomically: true,
                                 encoding: .utf8)
        log("created example config: \(configPath)")
    }

    func reloadIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configPath)
        guard let m = attrs?[.modificationDate] as? Date else {
            if !commands.isEmpty || mtime != nil {
                commands = []; mtime = nil; log("config missing -> 0 commands")
            }
            return
        }
        if m == mtime { return }
        mtime = m
        let text = (try? String(contentsOfFile: configPath,
                                encoding: .utf8)) ?? ""
        commands = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        log("config loaded: \(commands.count) command(s)")
    }
}

final class FocusWatcher {
    private let config = Config()
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var appName: String = ""
    private var lastWindowID: CGWindowID = 0
    private var debounce: DispatchWorkItem?

    func start() {
        config.bootstrapExampleIfMissing()
        config.reloadIfChanged()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self,
                       selector: #selector(activeAppChanged(_:)),
                       name: NSWorkspace.didActivateApplicationNotification,
                       object: nil)
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(app, fire: false)   // 起動時の窓は記録のみ（発火しない）
        }
        log("started; config=\(configPath)")
    }

    @objc private func activeAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        attach(app, fire: true)
    }

    private func detach() {
        if let obs = observer, let el = appElement {
            AXObserverRemoveNotification(obs, el,
                kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(obs, el,
                kAXMainWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
    }

    private func attach(_ app: NSRunningApplication, fire: Bool) {
        detach()
        appPID = app.processIdentifier
        appName = app.localizedName ?? app.bundleIdentifier ?? ""
        let el = AXUIElementCreateApplication(appPID)
        appElement = el

        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon = refcon else { return }
            Unmanaged<FocusWatcher>.fromOpaque(refcon)
                .takeUnretainedValue()
                .evaluate(fire: true)
        }
        if AXObserverCreate(appPID, cb, &obs) == .success, let obs = obs {
            observer = obs
            let me = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, el,
                kAXFocusedWindowChangedNotification as CFString, me)
            AXObserverAddNotification(obs, el,
                kAXMainWindowChangedNotification as CFString, me)
            CFRunLoopAddSource(CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(obs), .defaultMode)
        }

        evaluate(fire: fire)
        if fire {   // 切替直後は AX 反映が数十msズレることがある→一拍後に再評価
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                [weak self] in self?.evaluate(fire: true)
            }
        }
    }

    /// 現在のフォーカス窓 (CGWindowID, title)。取得不可は (0, "")。
    private func focusedWindow() -> (CGWindowID, String) {
        guard let el = appElement else { return (0, "") }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el,
                kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value else { return (0, "") }
        let win = v as! AXUIElement
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(win, &wid) == .success else { return (0, "") }
        var t: CFTypeRef?
        let title = (AXUIElementCopyAttributeValue(win,
                        kAXTitleAttribute as CFString, &t) == .success
                     ? (t as? String) : nil) ?? ""
        return (wid, title)
    }

    private func evaluate(fire: Bool) {
        let (wid, title) = focusedWindow()
        guard wid != 0, wid != lastWindowID else { return }
        lastWindowID = wid
        guard fire else { return }
        // 連続発火を 50ms で1回に集約してからディスパッチ。
        debounce?.cancel()
        let pid = appPID, app = appName
        let work = DispatchWorkItem { [weak self] in
            self?.dispatch(windowID: wid, pid: pid, app: app, title: title)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func dispatch(windowID: CGWindowID, pid: pid_t,
                          app: String, title: String) {
        config.reloadIfChanged()   // 発火時に遅延 hot reload（タイマー無し）
        guard !config.commands.isEmpty else { return }

        var env = ProcessInfo.processInfo.environment
        env["FOCUSFX_EVENT"] = "window_focused"
        env["FOCUSFX_WINDOW_ID"] = String(windowID)
        env["FOCUSFX_PID"] = String(pid)
        env["FOCUSFX_APP"] = app
        env["FOCUSFX_TITLE"] = title

        log("window_focused win=\(windowID) app=\(app) "
            + "-> \(config.commands.count) cmd(s)")
        for cmd in config.commands {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.environment = env
            do {
                try p.run()
            } catch {
                log("spawn failed [\(cmd)]: \(error)")
                continue
            }
            // 暴走防止: 10s 超過は打ち切り（フォーカス処理はブロックしない）。
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if p.isRunning { p.terminate() }
            }
        }
    }
}

let trusted = AXIsProcessTrustedWithOptions(
    ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
if !trusted {
    log("accessibility NOT granted yet — grant in System Settings > "
        + "Privacy & Security > Accessibility, then restart focusfx")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let watcher = FocusWatcher()
watcher.start()
app.run()
