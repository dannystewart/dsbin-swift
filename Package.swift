// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dsbin-swift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swbuild", targets: ["SwiftBuilder"]),
        .executable(name: "swcompare", targets: ["SwiftCompare"]),
        .executable(name: "swconfigs", targets: ["SwiftConfigs"]),
        .executable(name: "swdeploy", targets: ["SwiftDeploy"]),
    ],
    dependencies: [
        .package(path: "../polykit-swift"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftBuilder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PolyKit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftBuilder",
        ),
        .executableTarget(
            name: "SwiftCompare",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PolyKit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftCompare",
        ),
        .executableTarget(
            name: "SwiftConfigs",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PolyKit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftConfigs",
            exclude: ["Templates"],
        ),
        .executableTarget(
            name: "SwiftDeploy",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PolyKit", package: "polykit-swift"),
            ],
            path: "Sources/SwiftDeploy",
        ),
    ],
)
