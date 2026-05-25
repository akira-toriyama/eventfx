# eventfx

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) · **日本語**

AX 由来のイベント（**フォーカス窓変化** / **テキスト選択変化**）を検知して、設定された任意コマンドを実行する macOS 常駐デーモン。純粋な受動オブザーバで、外部のウィンドウマネージャに依存しない。効果音・枠強調・ランチャー表示などの「効果」は設定（コマンド文字列）側の責務で、本体は **検知とディスパッチしか持たない（ゼロハードコード）**。

## 特徴

- **ポーリングしない**。`NSWorkspace.didActivateApplication` ＋ AX イベント駆動
- 2 種類のイベント: `window_focused`, `text_selected`。`$EVENTFX_EVENT` で分岐
- 最前面アプリ 1 つにだけ AX オブザーバを張替え＝軽量
- 設定はホットリロード（保存すれば次の発火時に自動反映・再起動不要）
- 追加依存なし（純 `swiftc`）

## アーキテクチャ

```mermaid
flowchart TD
    A[NSWorkspace.didActivateApplication] --> B[最前面アプリへ AX オブザーバ張替え]
    B --> C{AX 通知}
    C -- kAXFocusedWindowChanged<br/>kAXMainWindowChanged --> D[フォーカス窓 CGWindowID 変化?]
    C -- kAXSelectedTextChanged --> S[選択文字列を取得<br/>非空 &amp; 直前と変化?]
    D -- はい --> F[50ms デバウンス]
    S -- はい --> T[180ms デバウンス]
    F --> G[config を mtime 比較で遅延リロード]
    T --> G
    G --> H[各行を /bin/sh -c で実行<br/>EVENTFX_* を環境変数注入]
```

## 要件

- macOS 13 以降（Ventura+。Homebrew formula の `depends_on macos: :ventura` と一致）
- Xcode Command Line Tools（`swiftc`）。`NSWorkspace` と AX API を使用
- アクセシビリティ権限（初回プロンプト。後述）

## インストール

```sh
git clone https://github.com/akira-toriyama/eventfx.git ~/dev/eventfx
cd ~/dev/eventfx
./install.sh
```

`install.sh` は次を自己発見パスで行う（ユーザー名非依存）:

1. `build.sh` でビルド
2. `~/.local/bin/eventfx` へ配置
3. `~/Library/LaunchAgents/com.local.eventfx.plist` を生成（`EnvironmentVariables/PATH` 込み）
4. `launchctl` で LaunchAgent 登録（`RunAtLoad` / `KeepAlive`）

初回はシステム設定 > プライバシーとセキュリティ > アクセシビリティ で
`~/.local/bin/eventfx` を許可してください。

## 設定

`${XDG_CONFIG_HOME:-$HOME/.config}/eventfx/config`

- **1 行＝1 コマンド**（`/bin/sh -c` で実行）。空行と `#` 行は無視
- 保存すれば次の発火時に自動反映（mtime ホットリロード・タイマー無し）
- `$EVENTFX_EVENT` で種別を判定し、各行で必要に応じてガードする
- 各コマンドへ context を環境変数で注入:

| 変数 | イベント | 内容 |
|---|---|---|
| `EVENTFX_EVENT` | 両方 | `"window_focused"` または `"text_selected"` |
| `EVENTFX_PID` | 両方 | アプリの PID |
| `EVENTFX_APP` | 両方 | アプリ名 |
| `EVENTFX_WINDOW_ID` | `window_focused` | フォーカス窓の CGWindowID |
| `EVENTFX_TITLE` | `window_focused` | ウィンドウタイトル |
| `EVENTFX_SELECTION` | `text_selected` | 選択された文字列 |
| `EVENTFX_CURSOR_X` / `EVENTFX_CURSOR_Y` | `text_selected` | 発火時点のマウス座標（Cocoa 系・全スクリーン） |

例 — テキスト選択時にマウス近くへ wand ランチャーを開く:

```sh
[ "$EVENTFX_EVENT" = text_selected ] && \
  stroke --show-menu \
    --items "$HOME/.config/eventfx/text_selected.toml" \
    --at "$EVENTFX_CURSOR_X" "$EVENTFX_CURSOR_Y" \
    --selection "$EVENTFX_SELECTION"
```

config 不在時はサンプルが自動生成される。暴走防止のため各コマンドは 10 秒で打ち切り。

## アンインストール

```sh
launchctl bootout gui/$(id -u)/com.local.eventfx
rm ~/Library/LaunchAgents/com.local.eventfx.plist ~/.local/bin/eventfx
```

## トラブルシュート

- **何も起きない**: アクセシビリティ未許可の可能性。`~/.local/state/eventfx.log` を確認し、`~/.local/bin/eventfx` を許可して再起動
- **Homebrew コマンドが動かない**: launchd 既定 PATH に Homebrew は無い。plist の `EnvironmentVariables/PATH` で解決済（`install.sh` 生成）。独自に PATH 依存コマンドを足す場合は留意
- ログ: `~/.local/state/eventfx.log`（本体）、`~/.local/state/eventfx.{out,err}.log`（launchd）

## 開発

- 本体は単一ファイル `main.swift`。`./build.sh` で `bin/eventfx` を生成（git 管理外）
- 推奨コミット規約: gitmoji + Conventional Commits（強制はしない）
- リリースノートは `cliff.toml` に従い release ワークフローが自動生成

## ライセンス

[MIT](LICENSE) © 2026 akira-toriyama
