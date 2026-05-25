# Security Policy

## サポート範囲 / Supported

最新の `main` のみ。/ Only the latest `main`.

## セキュリティ上の前提 / Security model

eventfx は次の強い権限・能力を持ちます。利用者はこれを理解した上で使用してください。

eventfx has the following significant privileges. Users should understand them:

- **アクセシビリティ権限** が必要（フォーカス窓・テキスト選択の AX 通知購読に
  AX API を使用）。
  Requires Accessibility permission (uses the AX API to observe focused-window
  and text-selection notifications).
- **設定ファイルの各行を `/bin/sh -c` で実行する**。`${XDG_CONFIG_HOME:-$HOME/.config}/eventfx/config`
  に書かれた内容は、購読中のイベント（`window_focused` / `text_selected`）
  発火のたびにシェルで実行される。`text_selected` では選択文字列が
  `$EVENTFX_SELECTION` でコマンドへ渡るため、利用側でクオート漏れがあると
  シェル注入が成立し得る点に留意。
  Each config line is executed via `/bin/sh -c`. Anything written to the config
  file runs in a shell on every observed event (`window_focused` /
  `text_selected`). For `text_selected`, the selected text is passed as
  `$EVENTFX_SELECTION` — missing quoting in user-defined commands can enable
  shell injection.
- 非公開 API `_AXUIElementGetWindow` を使用（長年実績のある安定 API）。
  Uses the private API `_AXUIElementGetWindow`.

したがって **config ファイルは信頼できる内容のみ**にしてください。書き込み権限を持つ第三者は任意コード実行が可能になります。
Therefore keep the config trustworthy: anyone who can write to it can achieve
arbitrary code execution in your session.

## 脆弱性の報告 / Reporting a vulnerability

GitHub の **Security Advisories**（Private vulnerability reporting）から報告してください。
公開 issue には記載しないでください。
Please report via GitHub Security Advisories (private vulnerability reporting).
Do not file public issues for vulnerabilities.
