import ArgumentParser
import Foundation
import PolyText

@main
struct SwiftConfigs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swconfigs",
        abstract: "Download and manage Swift project configuration files",
    )

    struct ConfigFile {
        let name: String
        let isTemplate: Bool

        private let baseURL = "https://raw.githubusercontent.com/dannystewart/dsbin-swift/refs/heads/main/"

        init(name: String, isTemplate: Bool = false) {
            self.name = name
            self.isTemplate = isTemplate
        }

        var sourceURL: URL {
            if isTemplate {
                return URL(string: baseURL + "Templates/\(name)")!
            } else {
                return URL(string: baseURL + name)!
            }
        }

        var destinationURL: URL { // For templates, strip .template from the name
            let finalName = isTemplate ? name.replacingOccurrences(of: ".template", with: "") : name
            return URL(fileURLWithPath: "./\(finalName)")
        }
    }

    class ConfigManager {
        let configs: [ConfigFile] = [
            ConfigFile(name: ".gitignore"),
            ConfigFile(name: ".swiftformat"),
            ConfigFile(name: ".swiftlint.yml"),
            ConfigFile(name: "Package.swift", isTemplate: true),
            ConfigFile(name: "project.code-workspace", isTemplate: true),
        ]

        func updateConfigs() async throws {
            for config in configs {
                let fileExists = FileManager.default.fileExists(atPath: config.destinationURL.path)

                if fileExists {
                    if config.isTemplate { // Templates should never overwrite existing files
                        Text.printColor(
                            "- Skipping \(config.destinationURL.lastPathComponent) as it's a template and the file already exists",
                            .cyan,
                        )
                        continue
                    } else { // Live configs may be updated, so ask if we should overwrite
                        Text.printColor(
                            "File \(config.destinationURL.lastPathComponent) already exists. Overwrite? (y/N): ",
                            .yellow,
                            terminator: "",
                        )
                        let response = readLine()?.lowercased()
                        if response != "y", response != "yes" {
                            Text.printColor("- Skipping \(config.destinationURL.lastPathComponent)", .cyan)
                            continue
                        }
                    }
                }

                // Download the file from the remote source
                let (data, _) = try await URLSession.shared.data(from: config.sourceURL)
                try data.write(to: config.destinationURL)
                Text.printColor("✓ Downloaded \(config.destinationURL.lastPathComponent)", .green)
            }
        }
    }

    func run() async throws {
        let manager = ConfigManager()
        try await manager.updateConfigs()
    }
}
