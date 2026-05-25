# CLAUDE.md

このリポジトリで作業する Claude / エージェント向けの構造と制約。

## 何のソフトか

AX 由来のイベント（フォーカス窓変化・テキスト選択変化）を検知し、設定された
任意コマンドを実行する macOS 常駐デーモン。外部 WM 非依存の受動オブザーバ。
**検知とディスパッチのみ**を担い、効果（音・枠・ランチャー等）は config 側の
責務（ゼロハードコード）。`$EVENTFX_EVENT` で種別を分岐:

- `window_focused`: 追加 env = `EVENTFX_WINDOW_ID`, `EVENTFX_TITLE`
- `text_selected`: 追加 env = `EVENTFX_SELECTION`, `EVENTFX_CURSOR_X/Y`
  （マウス座標は Cocoa 系。wand `stroke --show-menu --at` と整合）

## 構成

- `main.swift` — 本体（単一ファイル）。Cocoa + ApplicationServices。
- `build.sh` — `swiftc -O` で `bin/eventfx` を生成。追加依存なし。
- `install.sh` — build → `~/.local/bin/eventfx` 配置 → plist 生成 → launchd 登録。
  自分の位置と `$HOME` を実行時に自己発見（ユーザー名非依存）。
- `com.local.eventfx.plist.in` — LaunchAgent テンプレ。`@@BIN@@`/`@@HOME@@` を
  install.sh が置換。`EnvironmentVariables/PATH` で Homebrew/`~/.local/bin` を通す
  （launchd 既定 PATH に無く、config が呼ぶコマンドが無音失敗する根本対策）。
- `bin/` — ビルド成果物。**git 管理外**（`.gitignore`）。

## 制約・方針

- macOS 14+ 専用。非公開 API `_AXUIElementGetWindow` を使用（安定実績あり）。
- ポーリング禁止（AX イベント駆動）。最前面アプリ 1 つにのみオブザーバを張る。
- config は mtime ホットリロード（タイマー禁止）。各コマンドは 10s で打ち切り。
- **スコープ確定（再提案しないこと）**: `eventfx vibrate`（ウィンドウ振動）と
  内側ボーダー（inset border）は **検討の上、取りやめ**。前者はタイル型 WM と
  原理的に不整合、後者は外部ツールで不可かつ自作も見送り。geometric 追加演出は
  しない方針。効果は afplay / borders 等を config から呼ぶ形で完結。

## 開発

- 推奨コミット規約: gitmoji + Conventional Commits（強制はしない）。
- CI: `.github/workflows/`（build / shellcheck / release）。
- リリースノートは release ワークフローが git-cliff（`cliff.toml`）で生成。
