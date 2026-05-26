# CLAUDE.md

このリポジトリで作業する Claude / エージェント向けの構造・制約・流儀。
人間の README は [README.md](README.md) / [README.ja.md](README.ja.md)。

## What this is

AX 由来のイベント (フォーカス窓変化・テキスト選択変化) を検知し、設定された
任意コマンドを `/bin/sh -c` で実行する macOS 常駐デーモン。**検知とディス
パッチしか担わない** — 効果 (音 / 枠 / ランチャー等) は config が呼ぶ
コマンドに完全に外出し (ゼロハードコード)。

イベント種別は `$EVENTFX_EVENT` で分岐:

| イベント | 追加 env | トリガ AX 通知 |
|---|---|---|
| `window_focused` | `EVENTFX_WINDOW_ID`, `EVENTFX_TITLE` | `kAXFocusedWindowChanged` / `kAXMainWindowChanged` |
| `text_selected` | `EVENTFX_SELECTION`, `EVENTFX_CURSOR_X/Y` | `kAXSelectedTextChanged` |

共通 env は `EVENTFX_PID`, `EVENTFX_APP`。`text_selected` の cursor 座標は
Cocoa 系 (ボトム左原点・全スクリーン)。wand `stroke --show-menu --at`
契約と直接整合する。

## Build / Run

ビルド + ランタイム依存は Xcode CLT (`swiftc`) のみ。SwiftPM を**敢えて使わない** —
本体が単一ファイルなので overhead に見合わない。

| script | 用途 |
|---|---|
| `./build.sh` | `swiftc -O` で `bin/eventfx` 生成 |
| `./run.sh` | build + stop existing + foreground 実行 (`--debug` 付き)。Ctrl+C 終了 |
| `./run.sh --install` | `install.sh` 委譲 (LaunchAgent 登録) |
| `./stop.sh` | brew service + LaunchAgent + stragglers 全停止 |
| `./install.sh` | build → `~/.local/bin/eventfx` 配置 → plist 生成 → launchd 登録。自己発見パス・ユーザー名非依存 |
| `./scripts/build-icon.sh` | SF Symbol から `AppIcon.icns` 生成 (`dot.radiowaves.left.and.right` / teal) |

Production は Homebrew (`brew install akira-toriyama/tap/eventfx`) 経由を
推奨。`./install.sh` は素の launchd 直登録ルート。

## Architecture (制約)

- **macOS 13+ (Ventura+)**。`packaging/homebrew/eventfx.rb` の `depends_on
  macos: :ventura` と一致。
- **非公開 API** `_AXUIElementGetWindow` を `@_silgen_name` で取り込む
  (CGWindowID 解決のため。長年実績ある安定 API)。
- **ポーリング禁止**。`NSWorkspace.didActivateApplication` で最前面アプリ
  切替を受け、最前面アプリ 1 つだけに AX オブザーバを張替え。
- **debounce**: window=50ms / selection=180ms で過剰発火を集約。
  `text_selected` は空選択・同一選択を抑止。
- **config は mtime hot reload**。タイマー禁止 — 発火時に mtime を見て
  必要なら遅延再読込。
- **各コマンドは 10s で打ち切り**。`Process.terminate()` の見張り
  goroutine 相当を `DispatchQueue.global().asyncAfter` で。

### スコープ確定 (再提案しないこと)

- `eventfx vibrate` (ウィンドウ振動) と内側ボーダー (inset border) は
  検討の上、**取りやめ**。前者はタイル型 WM と原理不整合、後者は外部
  ツールで不可かつ自作も見送り。
- geometric 追加演出はしない方針。効果は afplay / borders 等を config
  から呼ぶ形で完結。
- ingress (CLI subcommand / socket) は**現状不要**。検知自体を eventfx が
  AX で行うため、PopClip / 外部ツールからの注入経路は今のところ持たない。

## CLI surface

```
eventfx                 run as daemon (default)
eventfx --debug         run + stderr + /tmp/eventfx.log
eventfx --validate      parse config, print count, exit
eventfx --version       print version, exit
eventfx --help          print help, exit
```

`--debug` は production の `~/.local/state/eventfx.log` に加えて stderr と
`/tmp/eventfx.log` にも tee する (foreground 開発時に `tail -f` しやすい)。

## Config

パス: `${XDG_CONFIG_HOME:-$HOME/.config}/eventfx/config`

- **1 行 = 1 コマンド** (`/bin/sh -c` 引数として渡す)。**バックスラッシュ
  継続 (`\`) は効かない** — eventfx は行ごとに別コマンドとして発火する
  ため。改行を入れると意図しない 2 行目が無条件実行される。
- 空行と `#` 行は無視。
- 保存で次イベント発火時に mtime hot reload。
- 想定パターン: `[ "$EVENTFX_EVENT" = text_selected ] && cmd args...` の
  ように `$EVENTFX_EVENT` でガード。

config 不在時は `exampleConfig` から自動生成される ([main.swift](main.swift) 内に
リテラルで保持)。

## Debugging

| ログ先 | 条件 |
|---|---|
| `~/.local/state/eventfx.log` | 常時 (production) |
| stderr | `--debug` 付き |
| `/tmp/eventfx.log` | `--debug` 付き (家風 `/tmp/<app>.log`) |
| `~/.local/state/eventfx.{out,err}.log` | launchd 経由 |

調査の早道:

- まず `./bin/eventfx --validate` で config が読めるか・件数を確認
- 動作確認は `./run.sh` (foreground + `--debug`) → イベントが stderr に流れる
- 本番デーモンの様子は `tail -f ~/.local/state/eventfx.log`
- AX 未許可なら起動直後に "accessibility NOT granted yet" ログが出る

## Conventions

- **コミット**: gitmoji + Conventional Commits。
  `scripts/hooks/commit-msg` がチェック。有効化:
  `git config core.hooksPath scripts/hooks`
- **PR**: タイトルも同じ形式 (`commit-lint.yml` がチェック)。
- **コメント**: WHY を書く。WHAT は識別子で語る。多段の docstring は禁止。
- **依存**: 追加依存ゼロを死守 (`swiftc` のみ)。SwiftPM 化したくなったら
  CLAUDE.md を更新してから。

## CI (.github/workflows)

| ファイル | 役割 |
|---|---|
| `build.yml` | PR で macos runner 上 `./build.sh` |
| `shellcheck.yml` | shell スクリプトの lint |
| `commit-lint.yml` | commit / PR title が convention に従うか |
| `release.yml` | git-cliff (`cliff.toml`) でリリースノート生成 |
| `update-tap.yml` | release 後に `akira-toriyama/homebrew-tap` を自動 bump |

`update-tap.yml` は `HOMEBREW_TAP_TOKEN` (fine-grained PAT, contents:write
on tap repo) が必要。未設定なら no-op で安全に skip。

## References (家風ソース)

eventfx の流儀は以下 3 リポと意図的に揃えている (家風):

- [facet](https://github.com/akira-toriyama/facet) — workspace + window manager
- [chord](https://github.com/akira-toriyama/chord) — hotkey daemon
- [perch](https://github.com/akira-toriyama/perch) — keyboard-driven UI navigator

共通: README EN/JA 並行 / `run.sh` `stop.sh` / `scripts/build-icon.sh` /
SF Symbol アイコン / `--help` `--validate` `--debug` CLI / `/tmp/<app>.log`
debug ログ / commit-msg hook / 4-workflow CI / Homebrew tap 外出し。

連携先:
- [wand (stroke)](https://github.com/akira-toriyama/wand) — `text_selected`
  時に `stroke --show-menu` でランチャー表示する想定の連携先。Cocoa 座標
  契約は wand PR #28 で確定。
