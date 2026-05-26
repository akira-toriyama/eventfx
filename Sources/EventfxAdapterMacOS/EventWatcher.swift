import Cocoa
import ApplicationServices
import CoreGraphics
import EventfxCore

/// 最前面アプリの AX オブザーバを張り替え続け、フォーカス窓変化と
/// テキスト選択変化を検知して config の各コマンドを `/bin/sh -c` で
/// 実行する観測ループ。AX イベント駆動 (ポーリング無し)。
///
/// AX 通知は対象アプリの AXUIElement に張り、最前面アプリ切替時に
/// detach → attach。同時に張るのは常に 1 アプリ分だけ = 軽量。
///
/// PopClip 流の text_selected: AX 通知だけでなく、CGEventTap で観測した
/// **マウスドラッグ完了 (mouseDown → drag → mouseUp)** との AND を取って
/// fire する。キーボードのみの選択 (shift+arrow, cmd+a)、IME 変換中の
/// marked text、プログラム的な選択変更は除外される。
///
/// `@MainActor`: AX / NSWorkspace 通知も CGEventTap source も main run loop に
/// 載せるので観測ループ全体を main actor に閉じる。CGEventTap callback は
/// `@convention(c)` 必須なので nonisolated だが、属するプロパティを
/// `nonisolated(unsafe)` にして同 thread のシリアル更新で済ませる
/// (chord/perch と同じパターン)。
@MainActor
public final class EventWatcher {

    // MARK: - State

    private let config: Config
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var appPID: pid_t = 0
    private var appName: String = ""
    private var lastWindowID: CGWindowID = 0
    private var debounce: DispatchWorkItem?
    private var selectionDebounce: DispatchWorkItem?
    // c-callback (leftMouseDown) からもクリアするので nonisolated(unsafe)。
    // 同じ run loop serial アクセスを前提に置く。
    nonisolated(unsafe) private var lastSelection: String = ""

    // CGEventTap state — c-callback から直接書く。main run loop 上でのみ
    // 動くので実害ある race は発生しない (nonisolated(unsafe) はその表明)。
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var eventTapSource: CFRunLoopSource?
    nonisolated(unsafe) private var mouseDragInProgress = false
    nonisolated(unsafe) private var dragMoved = false
    nonisolated(unsafe) private var lastDragMouseUpAt: Date?
    nonisolated(unsafe) private var dragEndLocation: CGPoint?

    /// 直近の "drag-confirmed mouseUp" がこの窓内なら text_selected を
    /// マウス由来とみなす。AX 通知の 250ms debounce + 余裕で 0.5s。
    private static let mouseUpWindow: TimeInterval = 0.5

    /// fire 時点で「マウスが drag 終了位置からこの距離以上離れていない」
    /// ことを要求する。選択完了後にユーザがすぐ別の場所へ移動した場合の
    /// 発火を避ける追加ゲート。位置ベースなので jitter にも強い (微小な
    /// 動きでは引っかからない)。pixel 単位 (Cocoa points)。
    private static let maxDistanceFromDragEnd: CGFloat = 40

    // MARK: - Lifecycle

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
        setupMouseTap()
        Logger.shared.log("started; config=\(Paths.configPath)")
    }

    // MARK: - AX observer (focused window + selected text)

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

    // MARK: - window_focused dispatch

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

    // MARK: - text_selected dispatch (with mouse-drag gates)

    fileprivate func handleSelectionChanged() {
        if Logger.shared.debugMode {
            Logger.shared.log("selection-change notification received")
        }
        // ドラッグ中は 1 文字ずつ通知が来るので 250ms に集約。PopClip 体感に
        // 寄せた値。CGEventTap で mouseUp を直接検出しているので、ここの
        // 待ち時間は "AX の繰り返し通知をどれだけ待ち合わせるか" だけ。
        selectionDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireSelection() }
        selectionDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func fireSelection() {
        // PopClip 流ゲート 1: 直近 mouseUpWindow 内に drag-confirmed mouseUp
        // が来ていなければ fire しない。これがキーボード選択
        // (shift+arrow / cmd+a) や、プログラム的な選択変更を除外する核。
        guard let mouseUp = lastDragMouseUpAt,
              Date().timeIntervalSince(mouseUp)
                < EventWatcher.mouseUpWindow else {
            if Logger.shared.debugMode {
                let age = lastDragMouseUpAt.map {
                    String(format: "%.2fs", Date().timeIntervalSince($0))
                } ?? "never"
                Logger.shared.log("selection skipped: no recent drag-confirmed "
                    + "mouseUp (last=\(age))")
            }
            return
        }

        // PopClip 流ゲート 2: drag 終了位置から現在カーソルが大きく離れて
        // いないこと。選択完了 → すぐ別の場所へ移動した場合の発火を避ける。
        // 位置差分なので jitter (微小な手の震え) は許容、actual な移動だけ
        // 弾ける。
        if let dragEnd = dragEndLocation {
            let now = NSEvent.mouseLocation
            let dx = now.x - dragEnd.x
            let dy = now.y - dragEnd.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance > EventWatcher.maxDistanceFromDragEnd {
                if Logger.shared.debugMode {
                    Logger.shared.log("selection skipped: cursor moved "
                        + "\(Int(distance))px from drag-end")
                }
                return
            }
        }

        guard let app = appElement else { return }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef) == .success,
              let focused = focusedRef else {
            if Logger.shared.debugMode {
                Logger.shared.log("selection skipped: no focused UI element "
                    + "(AX not exposing element for this app)")
            }
            return
        }
        let elem = focused as! AXUIElement

        // IME 抑止: focused element の実選択範囲が 0 文字なら
        // (= ハイライト無し / marked text のみ動いてる状態) fire しない。
        // 日本語入力中の毎キーストロークで誤発火するのを防ぐ。
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem,
                kAXSelectedTextRangeAttribute as CFString,
                &rangeRef) == .success,
           let rangeVal = rangeRef {
            var range = CFRange()
            if AXValueGetValue(rangeVal as! AXValue, .cfRange, &range),
               range.length == 0 {
                if Logger.shared.debugMode {
                    Logger.shared.log("selection skipped: range length=0 "
                        + "(IME composing or cursor-only)")
                }
                return
            }
        }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem,
                kAXSelectedTextAttribute as CFString,
                &textRef) == .success,
              let sel = textRef as? String,
              !sel.isEmpty else {
            if Logger.shared.debugMode {
                Logger.shared.log("selection skipped: empty / unreadable "
                    + "selected text (AX may not expose text for this widget)")
            }
            return
        }
        if sel == lastSelection {
            if Logger.shared.debugMode {
                Logger.shared.log("selection skipped: same as previous")
            }
            return
        }
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

    // MARK: - Command dispatch (/bin/sh -c)

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

    // MARK: - CGEventTap (drag-confirmed mouseUp detection)

    /// 左マウス: down → dragged → up のシーケンスを観測する受動 (listenOnly)
    /// event tap を main run loop に張る。シーケンス中に少なくとも 1 回
    /// `leftMouseDragged` を見ていれば、上がりの `leftMouseUp` を
    /// "drag-confirmed" として `lastDragMouseUpAt` に記録する。
    /// 単純クリックや単発の up は record しない。
    private func setupMouseTap() {
        let mask: CGEventMask =
              (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: EventWatcher.tapCallback,
            userInfo: me) else {
            Logger.shared.log("event-tap: tapCreate FAILED — "
                + "Accessibility not granted? text_selected gating disabled")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.shared.log("event-tap: installed (left mouse down/drag/up)")
    }

    /// CGEventTap callback. `@convention(c)` 必須なので static + nonisolated。
    /// state 更新は `nonisolated(unsafe)` properties 経由で main run loop 上の
    /// シリアル実行を前提に行う。
    nonisolated private static let tapCallback: CGEventTapCallBack = {
        _, type, event, refcon in
        guard let refcon = refcon else {
            return Unmanaged.passUnretained(event)
        }
        let me = Unmanaged<EventWatcher>
            .fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .leftMouseDown:
            me.mouseDragInProgress = true
            me.dragMoved = false
            // 新しい drag = 新しいユーザ意図。同一 text の再選択でも
            // 発火させたいので lastSelection をリセットする。
            // 単純クリックや keyboard 選択は下流の drag-confirmed mouseUp
            // ゲートで弾かれるので、ここでリセットしても誤発火しない。
            me.lastSelection = ""
        case .leftMouseDragged:
            if me.mouseDragInProgress { me.dragMoved = true }
        case .leftMouseUp:
            if me.mouseDragInProgress && me.dragMoved {
                me.lastDragMouseUpAt = Date()
                me.dragEndLocation = NSEvent.mouseLocation
            }
            me.mouseDragInProgress = false
            me.dragMoved = false
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // OS が tap を一時無効化したら即 re-enable して状況をログに
            // 残す ("2 回目以降出ない" 系の原因がここなら可視化される)。
            if let tap = me.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.shared.log("event-tap: re-enabled after "
                    + (type == .tapDisabledByTimeout
                       ? "timeout" : "user-input disable"))
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
