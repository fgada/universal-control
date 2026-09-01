// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniversalControlMinimal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "universal-control-minimal",
            targets: ["UniversalControlMinimal"]
        ),
        .executable(
            name: "universal-control-mac-receiver",
            targets: ["UniversalControlMacReceiver"]
        )
    ],
    targets: [
        .executableTarget(
            name: "UniversalControlMinimal",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "UniversalControlMacReceiver",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network")
            ]
        )
    ]
)
