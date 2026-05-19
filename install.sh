#!/bin/sh
# focusfx をビルドし、LaunchAgent として登録する。
#
# どのマシン・どのユーザー名でも、このスクリプトは自分の位置から
# 正しい絶対パスを「自己発見」する（テンプレートエンジン・chezmoi 不要）。
#   - リポジトリ位置: $(dirname "$0") を絶対化
#   - 配置先・ログ : $HOME を実行時参照
# 会社PC / 個人PC で $HOME が変わっても同じスクリプトで動く。
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/focusfx"
PLIST="$HOME/Library/LaunchAgents/com.local.focusfx.plist"
LABEL="com.local.focusfx"

# 1. ビルド（bin/focusfx を生成）
"$DIR/build.sh"

# 2. 安定 PATH 位置へバイナリ配置（config からは "$HOME/.local/bin/focusfx" で呼べる）
mkdir -p "$HOME/.local/bin" "$HOME/.local/state"
install -m 0755 "$DIR/bin/focusfx" "$BIN"

# 3. テンプレートから plist 生成（自己発見した絶対パスを埋める）
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|@@BIN@@|$BIN|g" -e "s|@@HOME@@|$HOME|g" \
    "$DIR/com.local.focusfx.plist.in" > "$PLIST"

# 4. LaunchAgent 再登録（既存ジョブは入れ替え）
launchctl bootout  "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed: $BIN"
echo "loaded:    $PLIST"
echo "note: Accessibility 権限を システム設定 > プライバシーとセキュリティ"
echo "      > アクセシビリティ で $BIN に付与してください（初回のみ）。"
