// swift-tools-version: 6.4

import PackageDescription
import Foundation

let helperInfo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Packaging/PanelMonitorHelper-Info.plist")
    .path

let package = Package(
    name: "MacDashboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PanelService", targets: ["PanelService"]),
        .executable(name: "PanelMonitorHelper", targets: ["PanelMonitorHelper"]),
        .executable(name: "PanelAuthorize", targets: ["PanelAuthorize"]),
        .executable(name: "PanelHost", targets: ["PanelHost"]),
        .library(name: "PanelAPI", targets: ["PanelAPI"]),
        .library(name: "PanelConfig", targets: ["PanelConfig"]),
        .library(name: "PanelDomain", targets: ["PanelDomain"]),
        .library(name: "SystemMetrics", targets: ["SystemMetrics"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.27.0",
            traits: ["FullFoundation"]
        ),
    ],
    targets: [
        .target(name: "PanelConfig"),
        .target(name: "PanelDomain"),
        .target(
            name: "SystemMetrics",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "PanelAPI",
            dependencies: [
                "PanelDomain",
                "PanelConfig",
                "SystemMetrics",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "PanelService",
            dependencies: [
                "PanelAPI",
                "PanelConfig",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "PanelMonitorHelper",
            dependencies: ["SystemMetrics"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", helperInfo,
                ]),
            ]
        ),
        .executableTarget(
            name: "PanelAuthorize",
            dependencies: ["SystemMetrics"]
        ),
        .executableTarget(
            name: "PanelHost",
            dependencies: ["PanelConfig"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
    ]
)
