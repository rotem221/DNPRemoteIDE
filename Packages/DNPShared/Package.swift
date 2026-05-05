// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DNPShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DNPShared", targets: ["DNPShared"])
    ],
    targets: [
        .target(
            name: "DNPShared",
            path: "Sources/DNPShared"
        ),
        .testTarget(
            name: "DNPSharedTests",
            dependencies: ["DNPShared"],
            path: "Tests/DNPSharedTests"
        )
    ]
)
