#!/bin/sh
# main.swift をリリースビルドして bin/focusfx を生成。
# 純 swiftc（Xcode CLT）。追加依存なし。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
swiftc -O \
  -framework Cocoa -framework ApplicationServices \
  -o "$DIR/bin/focusfx" \
  "$DIR/main.swift"
echo "built: $DIR/bin/focusfx"
