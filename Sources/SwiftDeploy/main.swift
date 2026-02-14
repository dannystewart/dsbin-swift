import ArgumentParser
import Foundation
import PolyKit

// MARK: - SwiftDeploy

struct SwiftDeploy: ParsableCommand {
    // MARK: - Global Options

    struct GlobalOptions: ParsableArguments {
        @Option(
            name: .long,
            help: "Path to presets JSON. Defaults to ~/.config/swdeploy/presets.json.",
        )
        var config: String?

        @Flag(
            name: .long,
            help: "Print additional diagnostics for troubleshooting.",
        )
        var debug = false
    }

    static let configuration: CommandConfiguration = .init(
        commandName: "swdeploy",
        abstract: "Build, deploy, and package Swift/Xcode projects.",
        subcommands: [
            Build.self,
            Install.self,
            Deploy.self,
            Dev.self,
            PresetsCommand.self,
        ],
        defaultSubcommand: Deploy.self,
    )

    static let logger: PolyLog = .init()

    // MARK: - Presets Loading

    static func loadPresets(configPathOverride: String?) throws -> Presets {
        let resolvedPath = Presets.resolveConfigPath(overridePath: configPathOverride)
        return try Presets.load(from: resolvedPath)
    }

    // MARK: - Error Helpers

    func logAndExit(_ error: some LoggableError) -> Never {
        Self.logger.logAndExit(error)
    }

    func logAndThrow(_ error: some LoggableError) throws {
        try Self.logger.logAndThrow(error)
    }
}

extension SwiftDeploy {
    static func printInfo(_ message: String) {
        self.logger.info(message)
        self.writeLine(message, to: .standardOutput)
    }

    static func printWarning(_ message: String) {
        self.logger.warning(message)
        self.writeLine("warning: \(message)", to: .standardOutput)
    }

    static func printError(_ message: String) {
        self.logger.error(message)
        self.writeLine("error: \(message)", to: .standardError)
    }

    private static func writeLine(_ text: String, to handle: FileHandle) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }
}

SwiftDeploy.main()
