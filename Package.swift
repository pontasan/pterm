// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "pterm",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // C module: VT parser, ring buffer, UTF-8 decoder
        .target(
            name: "PtermCore",
            path: "Sources/PtermCore",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-O2"], .when(configuration: .release)),
                .unsafeFlags(["-Wall", "-Wextra", "-Werror", "-g"], .when(configuration: .debug))
            ]
        ),
        // Main Swift executable
        .executableTarget(
            name: "PtermApp",
            dependencies: ["PtermCore"],
            path: "Sources/PtermApp",
            exclude: [
                "Rendering/Shaders/terminal.metal"
            ],
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation")
            ]
        ),
        // C module tests
        .testTarget(
            name: "PtermCoreTests",
            dependencies: ["PtermCore"]
        ),
        // Swift module tests
        .testTarget(
            name: "PtermAppTests",
            dependencies: ["PtermApp"]
        )
    ]
)
