#!/bin/sh
# eventfx をビルドし、LaunchAgent として登録する。
#
# どのマシン・どのユーザー名でも、このスクリプトは自分の位置から
# 正しい絶対パスを「自己発見」する（テンプレートエンジン・chezmoi 不要）。
#   - リポジトリ位置: $(dirname "$0") を絶対化
#   - 配置先・ログ : $HOME を実行時参照
# 会社PC / 個人PC で $HOME が変わっても同じスクリプトで動く。
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/eventfx"
PLIST="$HOME/Library/LaunchAgents/com.local.eventfx.plist"
LABEL="com.local.eventfx"

# 1. ビルド（bin/eventfx を生成）
"$DIR/build.sh"

# 2. 安定 PATH 位置へバイナリ配置（config からは "$HOME/.local/bin/eventfx" で呼べる）
mkdir -p "$HOME/.local/bin" "$HOME/.local/state"
install -m 0755 "$DIR/bin/eventfx" "$BIN"

# 3. テンプレートから plist 生成（自己発見した絶対パスを埋める）
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|@@BIN@@|$BIN|g" -e "s|@@HOME@@|$HOME|g" \
    "$DIR/com.local.eventfx.plist.in" > "$PLIST"

# 4. LaunchAgent 再登録（既存ジョブは入れ替え）
launchctl bootout  "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed: $BIN"
echo "loaded:    $PLIST"

# 5. セルフチェック + AX 未許可なら System Settings の Accessibility ペインを
#    自動で開いてやる。"あとは GUI に従って toggle ON するだけ" の動線に
#    寄せる (家風 chord は文章で促すだけだが、ここはもう一歩踏み込む)。
echo
"$BIN" --doctor || true
if ! "$BIN" --doctor 2>/dev/null | grep -q "^✓ Accessibility"; then
    echo
    echo "→ AX 未許可: System Settings → Privacy & Security → Accessibility を開きます。"
    echo "  $BIN を + で追加して toggle ON してください (初回のみ)。"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
        2>/dev/null || true
fi
