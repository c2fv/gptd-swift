// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "gptd-swift",
    platforms: [.iOS(.v13)],
    products: [
        .library(
            name: "gptd-swift",
            targets: ["gptd-swift"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "gptd-swift"),
    ]
)
