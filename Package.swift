// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DSSwift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swbuilder", targets: ["SwiftBuilder"]),
        .library(
            name: "PolyLog",
            targets: ["PolyLog"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1")
    ],
    targets: [
        .target(
            name: "PolyLog",
            path: "Sources/PolyLog"
        ),
        .executableTarget(
            name: "SwiftBuilder",
            dependencies: [
                "PolyLog", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SwiftBuilder"
        ),
    ]
)
