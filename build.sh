#!/bin/sh
# Build eventfx via SwiftPM and place the release binary at
# `bin/eventfx` (the path the Homebrew formula and install.sh both
# consume).
#
# Codesign at the end with the persistent self-signed identity
# created by setup-signing-cert.sh — keeps the Accessibility grant
# stable across rebuilds. With no identity present, fall back to
# ad-hoc signing (correct but means TCC re-prompts on every rebuild).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

swift build -c release

mkdir -p bin
cp -f .build/release/eventfx bin/eventfx

# Codesign with persistent identity if available; else ad-hoc.
identity=""
if [ -f .signing-id ]; then
  identity="$(cat .signing-id)"
fi
if [ -n "$identity" ] && \
   security find-certificate -c "$identity" \
     "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign --force --options runtime --sign "$identity" bin/eventfx
  echo "built: $DIR/bin/eventfx  (signed: $identity)"
else
  codesign --force --sign - bin/eventfx
  echo "built: $DIR/bin/eventfx  (signed: ad-hoc — run ./setup-signing-cert.sh for stable AX grant)"
fi
