// swift-tools-version:5.9
//
// Vendored from migueldeicaza/SwiftTerm @ 1.13.0, trimmed to the library target only
// (the fuzz/termcast/benchmark/test targets and their deps are dropped).
//
// LOCAL PERFORMANCE PATCHES:
// - Terminal.snapshotBuffer deep-copies only the visible viewport during
//   synchronized output (ESC[?2026h, emitted per-frame by agent TUIs), and sizes
//   that temporary buffer to materialized content rather than 100k capacity.
// - Buffer.resize iterates populated lines rather than scrollback capacity. The
//   upstream loop materialized 100k blank rows on a normal pane resize in Argus.
// - StyledText exposes optionally bounded, attributed terminal snapshots so
//   print/render surfaces do not discard ANSI styling or retained history.
// - macOS display scheduling skips hidden views and exposes a redraw FPS cap;
//   terminal parsing/history remain lossless while cached panes avoid wasted paint.
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
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
