// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoHideAgent",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "AutoHideAgent", targets: ["AutoHideAgent"])
    ],
    targets: [
        .executableTarget(
            name: "AutoHideAgent",
            path: "Sources/AutoHideAgent",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "AutoHideAgentTests",
            dependencies: ["AutoHideAgent"],
            path: "Tests/AutoHideAgentTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
