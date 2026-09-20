// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Silica",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SilicaCore", targets: ["SilicaCore"]),
    ],
    targets: [
        .target(name: "SilicaCore"),
        .testTarget(name: "SilicaCoreTests", dependencies: ["SilicaCore"]),
    ]
)
