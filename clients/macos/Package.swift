// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UniversalTmuxMac",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Vendored locally (clients/macos/vendor/SwiftTerm) with a perf patch to
        // synchronized-output buffer snapshotting — see that package's Package.swift.
        .package(path: "vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "UniversalTmuxMac",
            dependencies: ["SwiftTerm"],
            linkerSettings: [
                // Embed Info.plist into the binary so macOS honors ATS (and other
                // Info.plist keys) for this SwiftPM executable — a loose bundle
                // plist is ignored for cleartext ATS exceptions.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ]),
            ]
        ),
    ]
)
