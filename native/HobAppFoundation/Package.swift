// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "HobAppFoundation",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HobAppCore", targets: ["HobAppCore"]),
        .executable(name: "HobMacShell", targets: ["HobMacShell"]),
        .executable(name: "HobAgent", targets: ["HobAgent"]),
        .executable(name: "HobFoundationBridge", targets: ["HobFoundationBridge"]),
    ],
    targets: [
        .target(name: "HobAppCore"),
        .executableTarget(
            name: "HobMacShell",
            dependencies: ["HobAppCore"]
        ),
        .executableTarget(
            name: "HobAgent",
            dependencies: ["HobAppCore"]
        ),
        .executableTarget(
            name: "HobFoundationBridge",
            dependencies: ["HobAppCore"]
        ),
        .testTarget(
            name: "HobAppCoreTests",
            dependencies: ["HobAppCore"]
        ),
    ]
)
