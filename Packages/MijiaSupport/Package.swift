// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MijiaSupport",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [.library(name: "MijiaSupport", targets: ["MijiaSupport"])],
    targets: [.target(name: "MijiaSupport")]
)
