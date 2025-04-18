// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BMVideoCache",
    platforms: [
        .iOS(.v14),
        .macOS(.v14),
        .tvOS(.v14),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "BMVideoCache",
            targets: ["BMVideoCache"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "BMVideoCache",
            dependencies: []
        ),
        .testTarget(
            name: "BMVideoCacheTests",
            dependencies: ["BMVideoCache"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
