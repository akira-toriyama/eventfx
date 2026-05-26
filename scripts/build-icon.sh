#!/bin/zsh
# Generate AppIcon.icns from an SF Symbol via a one-shot Swift script.
# Run when you change the symbol or palette; the generated AppIcon.icns
# is committed to the repo so users / installers don't have to re-render.
#
#   ./scripts/build-icon.sh                              # default symbol
#   ./scripts/build-icon.sh dot.radiowaves.right         # custom symbol
#
# Palette is teal-on-near-black (event-broker vibe). Update the bgColor
# / fgColor inline if the brand drifts.
set -e
cd "$(dirname "$0")/.."

SYMBOL="${1:-dot.radiowaves.left.and.right}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

cat > "$TMP/gen.swift" <<'EOF'
import AppKit
import Foundation

let symbol = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

// teal accent on near-black rounded square (event-broker theme)
let bgColor = NSColor(red: 0.05, green: 0.10, blue: 0.12, alpha: 1.0)
let fgColor = NSColor(red: 0.30, green: 0.82, blue: 0.78, alpha: 1.0)

func renderPNG(size: Int, path: String) {
    let pointSize = CGFloat(size) * 0.55
    let pCfg = NSImage.SymbolConfiguration(
        pointSize: pointSize, weight: .semibold)
    let cCfg = NSImage.SymbolConfiguration(paletteColors: [fgColor])
    let cfg = pCfg.applying(cCfg)
    guard let sym = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: nil),
          let configured = sym.withSymbolConfiguration(cfg) else {
        FileHandle.standardError.write(Data(
            "error: SF Symbol '\(symbol)' not available\n".utf8))
        exit(1)
    }
    let target = NSImage(
        size: NSSize(width: size, height: size), flipped: false
    ) { rect in
        bgColor.setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: CGFloat(size) * 0.22,
                     yRadius: CGFloat(size) * 0.22).fill()
        let s = configured.size
        let r = NSRect(
            x: (CGFloat(size) - s.width) / 2,
            y: (CGFloat(size) - s.height) / 2,
            width: s.width, height: s.height)
        configured.draw(in: r, from: .zero,
                        operation: .sourceOver, fraction: 1.0,
                        respectFlipped: false, hints: nil)
        return true
    }
    guard let tiff = target.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data(
            "error: PNG encode failed at \(size)\n".utf8))
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for s in sizes { renderPNG(size: s.px, path: outDir + "/" + s.name) }
EOF

swift "$TMP/gen.swift" "$SYMBOL" "$ICONSET"
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "wrote AppIcon.icns (symbol: $SYMBOL)"
