#!/bin/sh
# main.swift をリリースビルドして bin/eventfx を生成。
# 純 swiftc（Xcode CLT）。追加依存なし。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/bin"
swiftc -O \
  -framework Cocoa -framework ApplicationServices \
  -o "$DIR/bin/eventfx" \
  "$DIR/main.swift"
echo "built: $DIR/bin/eventfx"
