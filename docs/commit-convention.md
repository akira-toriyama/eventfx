# コミット規約 / Commit Convention

**gitmoji（任意・先頭）+ [Conventional Commits](https://www.conventionalcommits.org/)**

## 形式 / Format

```
[<gitmoji>] <type>(<scope>)!: <subject>
```

- `<gitmoji>` は任意。絵文字（✨）または ショートコード（`:sparkles:`）。
- `<type>` 必須: `feat` `fix` `docs` `style` `refactor` `perf` `test` `build`
  `ci` `chore` `revert`
- `<scope>` 任意。`!` は破壊的変更。
- `<subject>` 命令形・簡潔。

## 例 / Examples

```
:sparkles: feat: フォーカス窓タイトルを環境変数で注入
:bug: fix(install): 既存 LaunchAgent を入れ替えできない不具合
:pencil2: docs: README にトラブルシュートを追加
:recycle: refactor!: 設定リロードの API を変更
```

## 強制 / Enforcement

- ローカル: `git config core.hooksPath scripts/hooks`（`commit-msg` で検証）
- CI: `.github/workflows/commit-lint.yml` が PR の各コミットを検証

リリースノートは Conventional Commits を元に git-cliff（`cliff.toml`）が生成。
