// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BrowserKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BrowserKit",
            targets: ["BrowserKit"]
        ),
    ],
    targets: [
        .target(
            name: "BrowserKit",
            dependencies: [],
            path: "Sources/BrowserKit"
        ),
        .testTarget(
            name: "BrowserKitTests",
            dependencies: ["BrowserKit"],
            path: "Tests/BrowserKitTests"
        ),
    ]
)
