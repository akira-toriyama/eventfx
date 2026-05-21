# Canonical copy of the Homebrew formula. The live copy lives in the tap repo
# at akira-toriyama/homebrew-tap as Formula/focusfx.rb. Keep this in sync and
# bump `url`/`sha256` on every release tag (see packaging/homebrew/README.md).
class Focusfx < Formula
  desc "macOS daemon that runs commands on active window change"
  homepage "https://github.com/akira-toriyama/focusfx"
  # Reference copy. The REAL sha256 lives only in the tap's Formula/focusfx.rb
  # (a sha cannot self-reference the tarball that contains it). Per-release
  # steps: packaging/homebrew/README.md.
  url "https://github.com/akira-toriyama/focusfx/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/akira-toriyama/focusfx.git", branch: "main"

  # Builds with the Swift toolchain from Xcode or the Command Line Tools.
  depends_on macos: :ventura

  def install
    system "./build.sh"
    bin.install "bin/focusfx"
  end

  service do
    run [opt_bin/"focusfx"]
    run_at_load true
    keep_alive true
    process_type :interactive
    log_path var/"log/focusfx.log"
    error_log_path var/"log/focusfx.err.log"
    # launchd 既定 PATH には Homebrew が無いため、config から呼ぶコマンド
    # (borders など) を解決できるよう明示する。
    environment_variables PATH: "/opt/homebrew/bin:/opt/homebrew/sbin:" \
                                "/usr/local/bin:/usr/bin:/bin:" \
                                "/usr/sbin:/sbin"
  end

  def caveats
    <<~EOS
      focusfx is a background daemon. It watches the active (focused) window
      and dispatches commands from your config file:
        ${XDG_CONFIG_HOME:-$HOME/.config}/focusfx/config
      (a sample is auto-generated on first run if the file is missing).

      Start (also auto-runs at login afterward):
        brew services start focusfx

      Grant Accessibility to "focusfx" on first run (System Settings →
      Privacy & Security → Accessibility). Without it, the daemon can still
      detect application switches but cannot resolve the focused window
      inside an app.

      Stop:
        brew services stop focusfx

      Documentation: #{homepage}
    EOS
  end

  test do
    assert_path_exists bin/"focusfx"
  end
end
