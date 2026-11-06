// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MijiaTVPrototype",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)],
    products: [
        .library(name: "TVPrototypeKit", targets: ["TVPrototypeKit"]),
        .executable(name: "UDPFixtureHost", targets: ["UDPFixtureHost"])
    ],
    dependencies: [
        .package(path: ".generated/MijiaTVDependencies"),
        .package(path: "../../Vendor/hap-swift")
    ],
    targets: [
        .executableTarget(name: "UDPFixtureHost", dependencies: ["TVPrototypeKit"], path: "Tools/UDPFixtureHost"),
        .target(name: "TVPrototypeKit", dependencies: [
            .product(name: "MijiaLAN", package: "MijiaTVDependencies"),
            .product(name: "MijiaHomeKitBridge", package: "MijiaTVDependencies"),
            .product(name: "MijiaCore", package: "MijiaTVDependencies")
        ]),
        .testTarget(name: "TVPrototypeKitTests", dependencies: [
            "TVPrototypeKit", .product(name: "HAPCore", package: "hap-swift"),
            .product(name: "HAPCrypto", package: "hap-swift"),
            .product(name: "MijiaLAN", package: "MijiaTVDependencies"),
            .product(name: "MijiaHomeKitBridge", package: "MijiaTVDependencies"),
            .product(name: "MijiaCore", package: "MijiaTVDependencies")
        ])
    ]
)
