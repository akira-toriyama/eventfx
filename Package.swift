// swift-tools-version:6.0
//
// eventfx — macOS event-broker daemon.
//
// Architecture is hexagonal (Ports & Adapters), mirroring facet /
// chord / perch's three-layer split:
//
//   EventfxCore         pure logic: config parser, paths, logger.
//                       Foundation only. No AppKit, no AX.
//
//   EventfxAdapterMacOS real-world glue: AX observer for focus /
//                       text-selection notifications, Cocoa mouse
//                       location, /bin/sh dispatch. The ONLY place
//                       AX / Cocoa types appear.
//
//   EventfxApp          executable: @main, CLI argv, NSApplication
//                       setup, daemon launch.
//
// Tests live under Tests/EventfxCoreTests/. The detect side is small
// enough that we don't need an AdapterTest layer (chord uses one
// because of CGEventTap; we observe AX read-only).

import PackageDescription

let package = Package(
    name: "eventfx",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "eventfx", targets: ["EventfxApp"]),
        .library(name: "EventfxCore", targets: ["EventfxCore"]),
    ],
    targets: [
        .target(name: "EventfxCore"),
        .target(name: "EventfxAdapterMacOS", dependencies: ["EventfxCore"]),
        .executableTarget(
            name: "EventfxApp",
            dependencies: [
                "EventfxCore",
                "EventfxAdapterMacOS",
            ]),
        .testTarget(name: "EventfxCoreTests", dependencies: ["EventfxCore"]),
    ]
)
