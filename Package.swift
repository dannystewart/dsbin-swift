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
    targets: [
        .target(
            name: "PolyLog",
            path: "Sources/PolyLog"
        ),
        .executableTarget(name: "SwiftBuilder"),
    ]
)
