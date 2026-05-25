# Canonical copy of the Homebrew formula. The live copy lives in the tap repo
# at akira-toriyama/homebrew-tap as Formula/eventfx.rb. Keep this in sync and
# bump `url`/`sha256` on every release tag (see packaging/homebrew/README.md).
class Eventfx < Formula
  desc "macOS daemon that runs commands on AX events (window focus, text selection)"
  homepage "https://github.com/akira-toriyama/eventfx"
  # Reference copy. The REAL sha256 lives only in the tap's Formula/eventfx.rb
  # (a sha cannot self-reference the tarball that contains it). Per-release
  # steps: packaging/homebrew/README.md.
  url "https://github.com/akira-toriyama/eventfx/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/akira-toriyama/eventfx.git", branch: "main"

  # Builds with the Swift toolchain from Xcode or the Command Line Tools.
  depends_on macos: :ventura

  def install
    system "./build.sh"
    bin.install "bin/eventfx"
  end

  service do
    run [opt_bin/"eventfx"]
    run_at_load true
    keep_alive true
    process_type :interactive
    log_path var/"log/eventfx.log"
    error_log_path var/"log/eventfx.err.log"
    # launchd 既定 PATH には Homebrew が無いため、config から呼ぶコマンド
    # (borders など) を解決できるよう明示する。
    environment_variables PATH: "/opt/homebrew/bin:/opt/homebrew/sbin:" \
                                "/usr/local/bin:/usr/bin:/bin:" \
                                "/usr/sbin:/sbin"
  end

  def caveats
    <<~EOS
      eventfx is a background daemon. It observes AX events on the frontmost
      app — focused-window changes (window_focused) and text-selection changes
      (text_selected) — and dispatches commands from your config file:
        ${XDG_CONFIG_HOME:-$HOME/.config}/eventfx/config
      (a sample is auto-generated on first run if the file is missing). Branch
      with $EVENTFX_EVENT inside your commands.

      Start (also auto-runs at login afterward):
        brew services start eventfx

      Grant Accessibility to "eventfx" on first run (System Settings →
      Privacy & Security → Accessibility). Without it, the daemon can still
      detect application switches but cannot read the focused window or
      selected text inside an app — no events will be dispatched.

      Stop:
        brew services stop eventfx

      Documentation: #{homepage}
    EOS
  end

  test do
    assert_path_exists bin/"eventfx"
  end
end
