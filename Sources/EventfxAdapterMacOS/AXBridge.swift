import ApplicationServices

/// AXUIElement → CGWindowID 解決のための非公開関数ブリッジ。
/// 公開 API には対応物が無いが、Hammerspoon / yabai 等の長期実績がある
/// 安定パス。EventWatcher が一意な window 識別子を得るために使用。
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
