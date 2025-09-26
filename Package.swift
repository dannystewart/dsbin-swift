// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DSSwift",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swbuilder", targets: ["SwiftBuilder"])
    ],
    dependencies: [
        .package(url: "https://github.com/dannystewart/PolyLog-Swift.git", branch: "main")
    ],
    targets: [
        .executableTarget(name: "SwiftBuilder")
    ]
)
