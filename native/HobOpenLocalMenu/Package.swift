// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "HobOpenLocalMenu",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "HobServiceControl",
            targets: ["HobServiceControl"]
        ),
        .executable(
            name: "HobOpenLocalMenu",
            targets: ["HobOpenLocalMenu"]
        ),
    ],
    targets: [
        .target(name: "HobServiceControl"),
        .executableTarget(
            name: "HobOpenLocalMenu",
            dependencies: ["HobServiceControl"]
        ),
        .testTarget(
            name: "HobServiceControlTests",
            dependencies: ["HobServiceControl"]
        ),
    ]
)
