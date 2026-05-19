# Security Policy

## サポート範囲 / Supported

最新の `main` のみ。/ Only the latest `main`.

## セキュリティ上の前提 / Security model

focusfx は次の強い権限・能力を持ちます。利用者はこれを理解した上で使用してください。

focusfx has the following significant privileges. Users should understand them:

- **アクセシビリティ権限** が必要（フォーカス窓の解決に AX API を使用）。
  Requires Accessibility permission (uses the AX API to resolve the focused window).
- **設定ファイルの各行を `/bin/sh -c` で実行する**。`${XDG_CONFIG_HOME:-$HOME/.config}/focusfx/config`
  に書かれた内容は、フォーカス変更のたびにシェルで実行される。
  Each config line is executed via `/bin/sh -c`. Anything written to the config
  file runs in a shell on every focus change.
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
