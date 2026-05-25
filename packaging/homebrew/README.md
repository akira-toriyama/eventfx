# Homebrew distribution runbook

`eventfx` ships as a **formula in a personal tap** (build-from-source; no
notarization, matches the project's local-build design).

`eventfx.rb` here is the canonical, version-controlled copy. The live copy
Homebrew reads lives in a separate tap repo.

## One-time: create the tap

1. On GitHub, create a repo named **`homebrew-tap`** under `akira-toriyama`
   (the `homebrew-` prefix is required; `brew tap akira-toriyama/tap` maps to it).
2. Add the formula:

   ```sh
   git clone https://github.com/akira-toriyama/homebrew-tap
   mkdir -p homebrew-tap/Formula
   cp packaging/homebrew/eventfx.rb homebrew-tap/Formula/eventfx.rb
   ```

## Every release

Releases are automated by `.github/workflows/release.yml` (rolling-draft
model). You do **not** tag by hand.

1. Merge `feat:`/`fix:`/`perf:` commits to `main`. The Release workflow grows
   a single **draft** GitHub Release (version computed by git-cliff; the
   `eventfx` binary + `eventfx.sha256` attached). No tag yet.
2. When ready, **Publish** that draft in the GitHub UI. GitHub creates the
   tag (e.g. `v0.2.0`) on the target commit at publish time.
3. Point Homebrew at the new tag:

   ```sh
   V=v0.2.0   # the tag you just published
   curl -sL "https://github.com/akira-toriyama/eventfx/archive/refs/tags/$V.tar.gz" \
     | shasum -a 256
   ```

4. Update `url` (tag) and `sha256` in this file **and** the tap's
   `Formula/eventfx.rb`; commit & push the tap.

> The `eventfx` binary attached to the Release is a prebuilt, ad-hoc-signed
> binary for users without a Swift toolchain (Gatekeeper-unquarantine steps
> are in the release notes). The Homebrew formula still builds from the tag
> tarball.

## Verify

```sh
brew tap akira-toriyama/tap
brew install --build-from-source akira-toriyama/tap/eventfx
brew test akira-toriyama/tap/eventfx
brew services start eventfx
```

`brew install --HEAD akira-toriyama/tap/eventfx` builds from `main` without a
tag (handy for testing before cutting a release).

## Notes

- Single-file daemon. Built via `build.sh` (plain `swiftc -O`); no SwiftPM.
- LaunchAgent is provided through Homebrew's `service do` block (label
  `homebrew.mxcl.eventfx`). PATH is set in `environment_variables` so config
  commands resolve `borders` etc. that aren't on launchd's default PATH.
- Users grant **Accessibility** to `eventfx` themselves on first run.
- Homebrew core/cask submission needs notability; a personal tap has no such
  bar and is the right home for this project.
