// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dsbin-swift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swbuilder", targets: ["SwiftBuilder"]),
        .executable(name: "swcompare", targets: ["SwiftCompare"]),
        .executable(name: "swconfigs", targets: ["SwiftConfigs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        .package(url: "https://github.com/dannystewart/polykit-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftBuilder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Polykit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftBuilder",
        ),
        .executableTarget(
            name: "SwiftCompare",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Polykit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftCompare",
        ),
        .executableTarget(
            name: "SwiftConfigs",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Polykit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftConfigs",
            exclude: ["Templates"],
        ),
    ],
)
