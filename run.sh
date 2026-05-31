#!/bin/sh
# Build + deploy + (re)bootstrap eventfx — the default verification loop.
# Mirrors facet / perch's `run.sh = "deploy the latest"`.
#
#   ./run.sh                  build → install.sh (~/.local/bin → LaunchAgent)
#   ./run.sh --foreground     build → stop → foreground exec ./bin/eventfx
#   ./run.sh -f               (alias)
#
# Default routes through install.sh so the running daemon is *always*
# the binary we just built (no stale ~/.local/bin/eventfx surprise).
# Foreground mode is for one-shot debugging where you want stderr in
# the terminal — Ctrl+C to quit, but the LaunchAgent (if loaded)
# stays installed and KeepAlive will respawn it from the *installed*
# binary as soon as you Ctrl+C.
#
# Production install: `brew install akira-toriyama/tap/eventfx`
# (or run ./install.sh on a checkout).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

case "${1:-}" in
    -f|--foreground)
        ./build.sh
        ./stop.sh
        sleep 0.3
        export EVENTFX_DEBUG=1
        echo "launching ./bin/eventfx (EVENTFX_DEBUG=1, Ctrl+C to quit)"
        exec ./bin/eventfx
        ;;
    "")
        # Default: install + bootstrap. After this returns the daemon
        # is running the freshly built binary from ~/.local/bin/eventfx.
        exec ./install.sh
        ;;
    *)
        echo "unknown flag: $1" >&2
        echo "usage: ./run.sh [--foreground|-f]" >&2
        exit 2
        ;;
esac
