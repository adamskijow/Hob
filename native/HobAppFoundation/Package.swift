// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "HobAppFoundation",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "HobAppCore", targets: ["HobAppCore"]),
        .library(name: "HobAppStorage", targets: ["HobAppStorage"]),
        .library(name: "HobAppleIntelligence", targets: ["HobAppleIntelligence"]),
        .library(name: "HobCalendar", targets: ["HobCalendar"]),
        .library(name: "HobAppExperience", targets: ["HobAppExperience"]),
        .executable(name: "HobMacShell", targets: ["HobMacShell"]),
        .executable(name: "HobAgent", targets: ["HobAgent"]),
        .executable(name: "HobFoundationBridge", targets: ["HobFoundationBridge"]),
    ],
    targets: [
        .target(name: "HobAppCore"),
        .target(
            name: "HobAppStorage",
            dependencies: ["HobAppCore"]
        ),
        .target(
            name: "HobAppleIntelligence",
            dependencies: ["HobAppCore"]
        ),
        .target(
            name: "HobCalendar",
            dependencies: ["HobAppCore"]
        ),
        .target(
            name: "HobAppExperience",
            dependencies: [
                "HobAppCore", "HobAppStorage", "HobAppleIntelligence",
                "HobCalendar",
            ]
        ),
        .executableTarget(
            name: "HobMacShell",
            dependencies: [
                "HobAppCore", "HobAppStorage", "HobAppleIntelligence",
                "HobAppExperience", "HobCalendar",
            ]
        ),
        .executableTarget(
            name: "HobAgent",
            dependencies: ["HobAppCore", "HobAppStorage"]
        ),
        .executableTarget(
            name: "HobFoundationBridge",
            dependencies: ["HobAppCore"]
        ),
        .testTarget(
            name: "HobAppCoreTests",
            dependencies: ["HobAppCore", "HobAppStorage"]
        ),
        .testTarget(
            name: "HobAppExperienceTests",
            dependencies: [
                "HobAppCore", "HobAppStorage", "HobAppExperience",
            ]
        ),
    ]
)
