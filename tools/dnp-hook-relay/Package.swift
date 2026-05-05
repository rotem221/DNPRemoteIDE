// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "dnp-hook-relay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dnp-hook-relay", targets: ["dnp-hook-relay"])
    ],
    dependencies: [
        .package(path: "../../Packages/DNPShared")
    ],
    targets: [
        .executableTarget(
            name: "dnp-hook-relay",
            dependencies: ["DNPShared"],
            path: "Sources/dnp-hook-relay"
        )
    ]
)
