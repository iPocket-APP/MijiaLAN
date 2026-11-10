// swift-tools-version: 6.1
// MijiaLAN uses its shared timing support to deploy to macOS 12.
import PackageDescription

let package = Package(
    name: "mdns-swift",
    platforms: [
        .macOS(.v12),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MDNSCore",  targets: ["MDNSCore"]),
        .library(name: "MDNSApple", targets: ["MDNSApple"]),
        .library(name: "MDNSLinux", targets: ["MDNSLinux"]),
    ],
    dependencies: [
        .package(path: "../../Packages/MijiaSupport"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "MDNSCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MDNSApple",
            dependencies: [
                .product(name: "MijiaSupport", package: "MijiaSupport"),
                "MDNSCore",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MDNSLinux",
            dependencies: [
                .product(name: "MijiaSupport", package: "MijiaSupport"),
                "MDNSCore",
                .product(name: "NIOCore",  package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging",  package: "swift-log"),
            ]
        ),
        .testTarget(name: "MDNSCoreTests",  dependencies: ["MDNSCore"]),
        .testTarget(
            name: "MDNSAppleTests",
            dependencies: ["MDNSApple", .product(name: "MijiaSupport", package: "MijiaSupport")]
        ),
        .testTarget(
            name: "MDNSLinuxTests",
            dependencies: [
                .product(name: "MijiaSupport", package: "MijiaSupport"),
                "MDNSLinux",
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
    ]
)
