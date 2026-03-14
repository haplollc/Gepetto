// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Gepetto",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Gepetto",
            targets: ["Gepetto"]
        ),
    ],
    targets: [
        .target(
            name: "Gepetto",
            dependencies: [],
            path: "Sources/Gepetto"
        ),
        .testTarget(
            name: "GepettoTests",
            dependencies: ["Gepetto"],
            path: "Tests/GepettoTests"
        ),
    ]
)
