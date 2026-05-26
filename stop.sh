#!/bin/sh
# Kill every running eventfx instance — brew service, LaunchAgent
# install, or raw build artifact. Use when you've lost track of
# which one is up (dev iteration loops pile up). Safe to run when
# nothing is running (no-op).
#
#   ./stop.sh
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# 1) brew service (HEAD or stable install)
if command -v brew >/dev/null 2>&1; then
    brew services stop akira-toriyama/tap/eventfx >/dev/null 2>&1 || true
fi

# 2) user-scope LaunchAgent (install.sh path)
launchctl bootout "gui/$(id -u)/com.local.eventfx" 2>/dev/null || true

# 3) Stragglers: anything still pointing at an eventfx binary.
pkill -f '/bin/eventfx'              2>/dev/null || true
pkill -f "$DIR/bin/eventfx"          2>/dev/null || true

# Confirmation pass
remaining="$(pgrep -fl 'eventfx' | grep -vE 'stop\.sh|run\.sh|grep' || true)"
if [ -n "$remaining" ]; then
    echo "warning: some eventfx instances survived:" >&2
    echo "$remaining" >&2
    exit 1
fi
echo "stopped: all eventfx instances"
