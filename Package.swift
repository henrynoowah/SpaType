// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaType",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpaType", targets: ["SpaType"]),
        .library(name: "SpaTypeCore", targets: ["SpaTypeCore"]),
    ],
    targets: [
        // Platform-independent engine: keystrokes -> candidates per input source -> verdict.
        .target(name: "SpaTypeCore"),
        // macOS menu bar agent: event tap, input sources, caret overlay, correction.
        .executableTarget(
            name: "SpaType",
            dependencies: ["SpaTypeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("NaturalLanguage"),
            ]
        ),
        .testTarget(name: "SpaTypeCoreTests", dependencies: ["SpaTypeCore"]),
    ]
)
