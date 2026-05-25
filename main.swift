// eventfx
//
// AX 由来のイベント（フォーカス窓変化 / テキスト選択変化）を検知して、設定
// された任意コマンドを実行する macOS 常駐デーモン。効果音・枠強調・ランチャー
// 等は「設定（コマンド文字列）」側の責務で、このバイナリは検知とディスパッチ
// しか知らない（ゼロハードコード）。
//
// 検知: ポーリングしない（AX イベント駆動）。
//   - NSWorkspace.didActivateApplication で最前面アプリ切替を受け、
//   - 最前面アプリの AXUIElement に AX オブザーバを張替え（最前面1つだけ＝軽量）:
//       * kAXFocusedWindowChanged / kAXMainWindowChanged → window_focused
//       * kAXSelectedTextChanged                         → text_selected
//   - 過剰発火は debounce で集約（window: 50ms / selection: 180ms）。
//   - text_selected は空選択・同一選択を抑止。
//
// 設定: ${XDG_CONFIG_HOME:-$HOME/.config}/eventfx/config
//   1行＝1コマンド（/bin/sh -c で実行）。空行と # 行は無視。保存で hot reload
//   （次の発火時に mtime を見て遅延再読込＝タイマー無し）。
//   各コマンドへ context を環境変数で注入:
//     共通:           EVENTFX_EVENT / EVENTFX_PID / EVENTFX_APP
//     window_focused: EVENTFX_WINDOW_ID / EVENTFX_TITLE
//     text_selected:  EVENTFX_SELECTION / EVENTFX_CURSOR_X / EVENTFX_CURSOR_Y
//                     （cursor は Cocoa 座標・全スクリーン。wand
//                     `stroke --show-menu --at` と直接整合する系）
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
let configDir = envOr("XDG_CONFIG_HOME", home + "/.config") + "/eventfx"
let configPath = configDir + "/config"
let logPath = home + "/.local/state/eventfx.log"

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
# eventfx — イベント発火のたびに以下のコマンドを /bin/sh -c で実行する。
# 1行＝1コマンド。# はコメント。保存すれば自動反映（hot reload・再起動不要）。
#
# イベント種別 ($EVENTFX_EVENT):
#   window_focused  アクティブ（フォーカス）ウィンドウが変わった
#   text_selected   テキスト選択が変化した（空選択へは発火しない）
#
# 共通の環境変数:
#   $EVENTFX_EVENT      上記いずれか
#   $EVENTFX_PID        アプリの PID
#   $EVENTFX_APP        アプリ名
#
# window_focused 時のみ:
#   $EVENTFX_WINDOW_ID  フォーカス窓の CGWindowID
#   $EVENTFX_TITLE      ウィンドウタイトル
#
# text_selected 時のみ:
#   $EVENTFX_SELECTION  選択された文字列
#   $EVENTFX_CURSOR_X   マウス座標 X (Cocoa 座標, 全スクリーン)
#   $EVENTFX_CURSOR_Y   マウス座標 Y (Cocoa 座標, 全スクリーン)

# 効果音（window_focused のみ）
[ "$EVENTFX_EVENT" = window_focused ] && \\
  afplay "${XDG_DATA_HOME:-$HOME/.local/share}/sounds/window_focused.wav"

# テキスト選択 → wand ランチャー（マウス近く）
# [ "$EVENTFX_EVENT" = text_selected ] && \\
#   stroke --show-menu \\
#     --items "$HOME/.config/eventfx/text_selected.toml" \\
#     --at "$EVENTFX_CURSOR_X" "$EVENTFX_CURSOR_Y" \\
#     --selection "$EVENTFX_SELECTION"
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

final class EventWatcher {
    private let config = Config()
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var appName: String = ""
    private var lastWindowID: CGWindowID = 0
    private var debounce: DispatchWorkItem?
    private var selectionDebounce: DispatchWorkItem?
    private var lastSelection: String = ""

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
            AXObserverRemoveNotification(obs, el,
                kAXSelectedTextChangedNotification as CFString)
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
        lastSelection = ""   // アプリ切替で抑止履歴をリセット
        let el = AXUIElementCreateApplication(appPID)
        appElement = el

        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon = refcon else { return }
            let watcher = Unmanaged<EventWatcher>.fromOpaque(refcon)
                .takeUnretainedValue()
            if (notification as String) == kAXSelectedTextChangedNotification {
                watcher.handleSelectionChanged()
            } else {
                watcher.evaluate(fire: true)
            }
        }
        if AXObserverCreate(appPID, cb, &obs) == .success, let obs = obs {
            observer = obs
            let me = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, el,
                kAXFocusedWindowChangedNotification as CFString, me)
            AXObserverAddNotification(obs, el,
                kAXMainWindowChangedNotification as CFString, me)
            // 選択変更通知はアプリ要素経由で購読（descendant の text element の
            // 変更も受け取れるのが macOS AX の通常挙動）。AX を出さないアプリ
            // (Chrome web view 等) には届かない点だけ仕様として許容する。
            AXObserverAddNotification(obs, el,
                kAXSelectedTextChangedNotification as CFString, me)
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
        let work = DispatchWorkItem { [weak self] in
            self?.dispatchCommands(
                event: "window_focused",
                extraEnv: [
                    "EVENTFX_WINDOW_ID": String(wid),
                    "EVENTFX_TITLE": title,
                ],
                logDetail: "win=\(wid)")
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    fileprivate func handleSelectionChanged() {
        // ドラッグ中は 1 文字ずつ通知が来るので 180ms に集約。
        selectionDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSelection() }
        selectionDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func fireSelection() {
        guard let app = appElement else { return }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef) == .success,
              let focused = focusedRef else { return }
        let elem = focused as! AXUIElement
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem,
                kAXSelectedTextAttribute as CFString,
                &textRef) == .success,
              let sel = textRef as? String,
              !sel.isEmpty else { return }
        if sel == lastSelection { return }   // 同一選択の再発火を抑止
        lastSelection = sel

        let p = NSEvent.mouseLocation   // Cocoa 座標（wand --show-menu と整合）
        dispatchCommands(
            event: "text_selected",
            extraEnv: [
                "EVENTFX_SELECTION": sel,
                "EVENTFX_CURSOR_X": String(format: "%.0f", p.x),
                "EVENTFX_CURSOR_Y": String(format: "%.0f", p.y),
            ],
            logDetail: "len=\(sel.count) at=(\(Int(p.x)),\(Int(p.y)))")
    }

    private func dispatchCommands(event: String,
                                  extraEnv: [String: String],
                                  logDetail: String) {
        config.reloadIfChanged()   // 発火時に遅延 hot reload（タイマー無し）
        guard !config.commands.isEmpty else { return }

        var env = ProcessInfo.processInfo.environment
        env["EVENTFX_EVENT"] = event
        env["EVENTFX_PID"] = String(appPID)
        env["EVENTFX_APP"] = appName
        for (k, v) in extraEnv { env[k] = v }

        log("\(event) \(logDetail) app=\(appName) "
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
            // 暴走防止: 10s 超過は打ち切り（ディスパッチはブロックしない）。
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
        + "Privacy & Security > Accessibility, then restart eventfx")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let watcher = EventWatcher()
watcher.start()
app.run()
