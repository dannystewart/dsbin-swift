import ArgumentParser
import Foundation
import Polykit

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
                URL(string: baseURL + "Templates/\(name)")!
            } else {
                URL(string: baseURL + name)!
            }
        }

        var destinationURL: URL { // For templates, strip .template from the name
            let finalName = isTemplate ? name.replacingOccurrences(of: ".template", with: "") : name

            // code-workspace files should use the parent directory as the filename
            if finalName == "project.code-workspace" {
                let parentDirName = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .lastPathComponent
                return URL(fileURLWithPath: "./\(parentDirName).code-workspace")
            }

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

        // Helper struct to track config file status
        struct ConfigStatus {
            let fileExists: Bool
        }

        func updateConfigs() async throws {
            // Check which configs need updates
            let configStatuses = await withTaskGroup(of: (ConfigFile, ConfigStatus).self) { group in
                var results: [(ConfigFile, ConfigStatus)] = []

                for config in configs {
                    group.addTask {
                        let fileExists = FileManager.default.fileExists(atPath: config.destinationURL.path)
                        return (config, ConfigStatus(fileExists: fileExists))
                    }
                }

                for await (config, status) in group {
                    results.append((config, status))
                }

                return results
            }

            // Process each config based on its status
            for (config, status) in configStatuses {
                try await processConfig(config, status: status)
            }
        }

        // Helper method to process individual configs
        private func processConfig(_ config: ConfigFile, status: ConfigStatus) async throws {
            if status.fileExists {
                if config.isTemplate { // Templates should never overwrite existing files
                    Text.printColor(
                        "- Skipping \(config.destinationURL.lastPathComponent) as it's a template and the file already exists",
                        .cyan,
                    )
                    return
                } else { // Live configs may be updated, so show diff and ask if we should overwrite
                    // Download the remote content first to compare
                    let (remoteData, _) = try await URLSession.shared.data(from: config.sourceURL)
                    let remoteContent = String(data: remoteData, encoding: .utf8) ?? ""

                    // Read local content
                    let localContent = try String(contentsOf: config.destinationURL, encoding: .utf8)

                    // Show diff if content is different
                    if localContent != remoteContent {
                        Text.printColor(
                            "\n--- Changes detected in \(config.destinationURL.lastPathComponent) ---",
                            .yellow,
                        )
                        _ = PolyDiff.content(
                            old: localContent,
                            new: remoteContent,
                            filename: config.destinationURL.lastPathComponent,
                        )
                        Text.printColor("--- End of changes ---\n", .yellow)
                    } else {
                        Text.printColor(
                            "- No changes needed for \(config.destinationURL.lastPathComponent)",
                            .cyan,
                        )
                        return
                    }

                    Text.printColor(
                        "Update \(config.destinationURL.lastPathComponent)? (y/N): ",
                        .yellow,
                        terminator: "",
                    )

                    // Read single character without requiring Enter
                    let response = PolyTerm.readSingleChar()
                    print()
                    if response.lowercased() != "y" {
                        Text.printColor("- Skipping \(config.destinationURL.lastPathComponent)", .cyan)
                        return
                    }

                    // Write the updated content
                    try remoteData.write(to: config.destinationURL)
                    Text.printColor("✓ Updated \(config.destinationURL.lastPathComponent)", .green)
                    return
                }
            }

            // Download the file from the remote source for new files
            let (data, _) = try await URLSession.shared.data(from: config.sourceURL)
            try data.write(to: config.destinationURL)
            Text.printColor("✓ Downloaded \(config.destinationURL.lastPathComponent)", .green)
        }
    }

    func run() async throws {
        let manager = ConfigManager()
        try await manager.updateConfigs()
    }
}
