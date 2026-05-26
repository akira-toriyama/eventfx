#!/bin/sh
# Build + foreground-launch eventfx for dev iteration. Stops any
# currently-running instance first so the fresh binary takes over
# cleanly (no double-observer state). Ctrl+C to quit.
#
#   ./run.sh             build → stop existing → exec bin/eventfx
#   ./run.sh --install   build → install.sh (LaunchAgent, background)
#
# Production install is via Homebrew (`brew install akira-toriyama/tap/eventfx`)
# or the bundled install.sh. This script is for local development —
# logs go to stderr so you see events as they fire.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ "${1:-}" = "--install" ]; then
    exec ./install.sh
fi

./build.sh
./stop.sh
sleep 0.3
echo "launching bin/eventfx (Ctrl+C to quit)"
exec ./bin/eventfx --debug
