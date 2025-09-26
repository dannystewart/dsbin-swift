// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dsbin-swift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swbuilder", targets: ["SwiftBuilder"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
        .package(url: "https://github.com/dannystewart/polykit-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftBuilder",
            dependencies: [
                .product(name: "PolyLog", package: "polykit-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SwiftBuilder"
        )
    ]
)
