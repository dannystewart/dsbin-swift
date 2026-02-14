import Foundation
import PolyKit

enum SwiftPMService {
    static func build(packagePath: String, configuration: String) throws {
        let swiftpmConfig = configuration.lowercased()
        guard swiftpmConfig == "debug" || swiftpmConfig == "release" else {
            throw DevError.invalidInput("Invalid SwiftPM configuration '\(configuration)'. Use Debug or Release.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["build", "-c", swiftpmConfig]
        process.currentDirectoryURL = URL(fileURLWithPath: packagePath)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DevError.buildFailed("swift build failed with exit code \(process.terminationStatus)")
        }
    }

    static func run(packagePath: String, target: String, configuration: String, runArguments: [String]) throws {
        let swiftpmConfig = configuration.lowercased()
        guard swiftpmConfig == "debug" || swiftpmConfig == "release" else {
            throw DevError.invalidInput("Invalid SwiftPM configuration '\(configuration)'. Use Debug or Release.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        var args = ["run", "-c", swiftpmConfig, target]
        if !runArguments.isEmpty {
            args.append("--")
            args.append(contentsOf: runArguments)
        }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: packagePath)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DevError.buildFailed("swift run failed with exit code \(process.terminationStatus)")
        }
    }

    /// Finds executable products or targets using `swift package dump-package`.
    static func findExecutables(packagePath: String) throws -> [String] {
        let dump = Process()
        dump.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        dump.arguments = ["package", "dump-package"]
        dump.currentDirectoryURL = URL(fileURLWithPath: packagePath)

        let outPipe = Pipe()
        dump.standardOutput = outPipe
        dump.standardError = Pipe()

        try dump.run()
        dump.waitUntilExit()

        guard dump.terminationStatus == 0 else {
            throw DevError.buildFailed("Failed to dump package manifest (exit code \(dump.terminationStatus)).")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return []
        }

        struct DumpPackage: Decodable {
            struct Product: Decodable {
                struct ProductType: Decodable {
                    private enum CodingKeys: String, CodingKey {
                        case executable, library, test, plugin, macro
                    }

                    let isExecutable: Bool

                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        self.isExecutable = container.contains(.executable)
                    }
                }

                let name: String
                let type: ProductType
            }

            struct Target: Decodable {
                let name: String
                let type: String?
            }

            let products: [Product]?
            let targets: [Target]?
        }

        let decoder = JSONDecoder()
        let manifest: DumpPackage
        do {
            manifest = try decoder.decode(DumpPackage.self, from: data)
        } catch {
            throw DevError.buildFailed("Could not parse dump-package JSON: \(error)")
        }

        var names = [String]()
        if let products = manifest.products {
            for product in products where product.type.isExecutable {
                names.append(product.name)
            }
        }

        if names.isEmpty, let targets = manifest.targets {
            for target in targets where target.type == "executable" {
                if !names.contains(target.name) {
                    names.append(target.name)
                }
            }
        }

        return names
    }
}
