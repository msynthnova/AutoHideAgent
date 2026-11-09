// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoHideAgent",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "AutoHideAgent", targets: ["AutoHideAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "AutoHideAgent",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
