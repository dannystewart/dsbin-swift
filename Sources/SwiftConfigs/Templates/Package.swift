// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "project-name",
    platforms: [
        .macOS(.v26),
    ],
    // You'll probably want to keep ONLY the library OR the executable depending on what you're building
    // This is designed to have everything you COULD need, not everything you WILL need, so thin down as needed
    products: [
        .library(name: "MyLibrary", targets: ["MyLibrary"]),
        .executable(name: "executable-command", targets: ["MyExecutable"]),
    ],
    dependencies: [
        .package(url: "../polykit-swift", branch: "main"),
    ],
    // Make sure the paths match up with the project structure
    targets: [
        .target(
            name: "MyLibrary",
            dependencies: [
                .product(name: "PolyKit", package: "polykit-swift"),
            ],
            path: "Sources/MyLibrary",
        ),
        .executableTarget(
            name: "MyExecutable",
            dependencies: [
                .product(name: "PolyKit", package: "polykit-swift"),
            ],
            path: "Sources/MyExecutable",
        ),
    ],
)
