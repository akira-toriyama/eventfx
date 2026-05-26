import Cocoa
import ApplicationServices
import EventfxCore

/// 最前面アプリの AX オブザーバを張り替え続け、フォーカス窓変化と
/// テキスト選択変化を検知して config の各コマンドを `/bin/sh -c` で
/// 実行する観測ループ。AX イベント駆動 (ポーリング無し)。
///
/// AX 通知は対象アプリの AXUIElement に張り、最前面アプリ切替時に
/// detach → attach。同時に張るのは常に 1 アプリ分だけ = 軽量。
///
/// `@MainActor`: AX 通知も NSWorkspace 通知も main run loop で配信される
/// ため、観測ループ全体を main actor に閉じる。Swift 6 strict concurrency
/// での data-race 警告を回避するための表明 (実態は元から main thread)。
@MainActor
public final class EventWatcher {
    private let config: Config
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var appName: String = ""
    private var lastWindowID: CGWindowID = 0
    private var debounce: DispatchWorkItem?
    private var selectionDebounce: DispatchWorkItem?
    private var lastSelection: String = ""

    public init(config: Config) {
        self.config = config
    }

    public func start() {
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
        Logger.shared.log("started; config=\(Paths.configPath)")
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
        // PopClip 体感に寄せた 250ms の "落ち着き" 待ち。AX 通知は 1 文字選択
        // ごとに来るのでドラッグ中は常に再スケジュールされ、ユーザが手を止め
        // た瞬間にだけ fire する形になる。CGEventTap で mouseUp を直接検出す
        // ればもっと正確だが、それは別件 (event tap 導入は構造変更)。
        selectionDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSelection() }
        selectionDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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

        Logger.shared.log("\(event) \(logDetail) app=\(appName) "
            + "-> \(config.commands.count) cmd(s)")
        for cmd in config.commands {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.environment = env
            do {
                try p.run()
            } catch {
                Logger.shared.log("spawn failed [\(cmd)]: \(error)")
                continue
            }
            // 暴走防止: 10s 超過は打ち切り（ディスパッチはブロックしない）。
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if p.isRunning { p.terminate() }
            }
        }
    }
}
