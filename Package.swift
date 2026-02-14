// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dsbin-swift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swbuild", targets: ["SwiftBuilder"]),
        .executable(name: "swdeploy", targets: ["SwiftDeploy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dannystewart/polykit-swift.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftBuilder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PolyKit", package: "polykit-swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/SwiftBuilder",
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
