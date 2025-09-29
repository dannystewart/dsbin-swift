// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "project-name",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "YourLibrary", targets: ["YourLibrary"]),
        .executable(name: "executable", targets: ["YourExecutable"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        .package(url: "https://github.com/dannystewart/polykit-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "YourLibrary",
            dependencies: [
                .product(name: "PolyLog", package: "polykit-swift"),
            ],
            path: "Sources/YourLibrary"
        ),
        .executableTarget(
            name: "YourExecutable",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "PolyLog", package: "polykit-swift"),
            ],
            path: "Sources/YourExecutable"
        ),
    ]
)
