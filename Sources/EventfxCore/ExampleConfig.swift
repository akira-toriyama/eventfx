/// Default config written when `~/.config/eventfx/config` is absent.
/// Demonstrates both event kinds and the env-var-based dispatch
/// pattern. Kept here (Core) so it travels with the Config class
/// that auto-creates it.
public let exampleConfig = """
# eventfx — イベント発火のたびに以下のコマンドを /bin/sh -c で実行する。
# 1行＝1コマンド。# はコメント。保存すれば自動反映（hot reload・再起動不要）。
#
# 重要: バックスラッシュ継続 (\\) は効かない。eventfx は行ごとに
# 別コマンドとして渡すため、1 コマンドは必ず物理 1 行で書く。
#
# イベント種別 ($EVENTFX_EVENT):
#   window_focused  アクティブ（フォーカス）ウィンドウが変わった
#   text_selected   テキスト選択が変化した（空選択へは発火しない）
#
# 共通の環境変数 (両イベント):
#   $EVENTFX_EVENT      上記いずれか
#   $EVENTFX_PID        アプリの PID
#   $EVENTFX_APP        アプリ名
#   $EVENTFX_WINDOW_ID  フォーカス窓の CGWindowID (取得不可は 0)
#   $EVENTFX_TITLE      フォーカス窓のタイトル (取得不可は空)
#
# text_selected 時のみ:
#   $EVENTFX_SELECTION  選択された文字列
#   $EVENTFX_CURSOR_X   マウス座標 X (Cocoa 座標, 全スクリーン)
#   $EVENTFX_CURSOR_Y   マウス座標 Y (Cocoa 座標, 全スクリーン)

# 効果音（window_focused のみ）
[ "$EVENTFX_EVENT" = window_focused ] && afplay "${XDG_DATA_HOME:-$HOME/.local/share}/sounds/window_focused.wav"

# テキスト選択 → wand ランチャー（マウス近く）
# [ "$EVENTFX_EVENT" = text_selected ] && stroke --show-menu --items "$HOME/.config/eventfx/text_selected.toml" --at "$EVENTFX_CURSOR_X" "$EVENTFX_CURSOR_Y" --selection "$EVENTFX_SELECTION"
"""
