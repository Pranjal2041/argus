// swift-tools-version:5.9
//
// Vendored from migueldeicaza/SwiftTerm @ 1.13.0, trimmed to the library target only
// (the fuzz/termcast/benchmark/test targets and their deps are dropped).
//
// LOCAL PATCH — Sources/SwiftTerm/Terminal.swift, `snapshotBuffer`: during
// synchronized output (ESC[?2026h, emitted per-frame by agent TUIs) the original
// deep-copied the ENTIRE buffer including all scrollback, every frame, for every
// terminal — which pinned the main thread in memcpy and bloated memory with many
// open terminals. The patch deep-copies only the visible viewport (the part that can
// change during a frame) and references the static scrollback. Search the file for
// "Only the visible viewport can change".
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
