// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "HobCalendarBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HobCalendarBridge",
            linkerSettings: [.linkedFramework("EventKit")]
        )
    ]
)
