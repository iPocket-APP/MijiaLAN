// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MijiaLAN",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MijiaLAN", targets: ["MijiaLAN"]),
        .library(name: "MijiaHomeKitBridge", targets: ["MijiaHomeKitBridge"]),
        .executable(name: "MijiaLANApp", targets: ["MijiaLANApp"]),
        .executable(name: "mijia-lan", targets: ["mijia-lan"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        // Locally maintained MIoT parsing, device synthesis, QR login and HomeStore.
        // Recovered from MenuBarMijia 1.1.4; see Vendor/MenuBarMijia/README.md.
        .package(path: "Vendor/MenuBarMijia"),
        // HomeKit Accessory Protocol server: acumen-dev/hap-swift at 638001b with local fixes; see Vendor/hap-swift/README.md.
        .package(path: "Vendor/hap-swift"),
        // hap-swift's logging API; the app sends it to the unified log.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        // miIO LAN protocol (UDP 54321), discovery, the device registry and a `MiCloudAPI` that never leaves the LAN.
        .target(
            name: "MijiaLAN",
            dependencies: [.product(name: "MijiaCore", package: "MenuBarMijia")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MijiaHomeKitBridge",
            dependencies: [
                "MijiaLAN",
                .product(name: "MijiaCore", package: "MenuBarMijia"),
                .product(name: "HAPSwift", package: "hap-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MijiaLANApp",
            dependencies: [
                "MijiaLAN",
                "MijiaHomeKitBridge",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MijiaCore", package: "MenuBarMijia"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command-line probe for the LAN layer: discover, info, props, set.
        .executableTarget(
            name: "mijia-lan",
            dependencies: [
                "MijiaLAN",
                "MijiaHomeKitBridge",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaLANAppTests",
            dependencies: [
                "MijiaLANApp",
                "MijiaLAN",
                "MijiaHomeKitBridge",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaLANTests",
            dependencies: [
                "MijiaLAN",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaHomeKitBridgeTests",
            dependencies: [
                "MijiaHomeKitBridge",
                .product(name: "MijiaCore", package: "MenuBarMijia"),
                .product(name: "HAPSwift", package: "hap-swift")
            ],
            // Trimmed miot-spec.org specifications of models without a bundled spec.
            resources: [.copy("Specs")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
