import ArgumentParser
import Foundation
import PolyKit

// MARK: - SwiftDeploy.Dev

extension SwiftDeploy {
    struct Dev: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "dev",
            abstract: "Local build/run/archive/packaging utilities (ported from swbuild).",
            subcommands: [
                Build.self,
                Run.self,
                Archive.self,
                Prepare.self,
                Link.self,
            ],
            defaultSubcommand: Build.self,
        )
    }
}

// MARK: - SwiftDeploy.Dev.Build

extension SwiftDeploy.Dev {
    struct Build: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "build",
            abstract: "Build an Xcode project/workspace or Swift package.",
        )

        @Argument(help: "Path to directory (or container) with Xcode project/workspace or Package.swift.")
        var projectPath: String?

        /// Long-only to avoid collisions with app args.
        @Option(name: .long, help: "Build configuration (Debug or Release).")
        var configuration: String = "Debug"

        func run() throws {
            let inputPath = self.projectPath ?? FileManager.default.currentDirectoryPath
            let projectType = try DevProjectResolver.determineProjectType(at: inputPath)
            try DevBuildOrchestrator.build(projectType: projectType, configuration: self.configuration)
        }
    }
}

// MARK: - SwiftDeploy.Dev.Run

extension SwiftDeploy.Dev {
    struct Run: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "run",
            abstract: "Build and run a local project/package.",
        )

        @Argument(help: "Path to directory (or container) with Xcode project/workspace or Package.swift.")
        var projectPath: String?

        @Option(name: .shortAndLong, help: "Target name for Swift packages with multiple executables.")
        var target: String?

        /// Long-only to avoid collisions with app args.
        @Option(name: .long, help: "Build configuration (Debug or Release).")
        var configuration: String = "Debug"

        @Flag(name: .long, help: "Kill existing process, build, then run.")
        var restart = false

        @Argument(parsing: .captureForPassthrough, help: "Arguments to pass to the executable.")
        var arguments: [String] = []

        func run() throws {
            let inputPath = self.projectPath ?? FileManager.default.currentDirectoryPath
            let projectType = try DevProjectResolver.determineProjectType(at: inputPath)
            try DevBuildOrchestrator.build(
                projectType: projectType,
                configuration: self.configuration,
            )

            if self.restart {
                DevBuildOrchestrator.killExistingProcess(named: projectType.defaultRunName)
            }

            try DevBuildOrchestrator.run(
                projectType: projectType,
                configuration: self.configuration,
                targetName: self.target,
                runArguments: self.arguments,
            )
        }
    }
}

// MARK: - SwiftDeploy.Dev.Archive

extension SwiftDeploy.Dev {
    struct Archive: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "archive",
            abstract: "Archive an Xcode project/workspace for release (version overrides only).",
        )

        @Argument(help: "Version for the archive (e.g., 1.2.3, 2.0-rc.1). Used for smart formatting unless overridden.")
        var version: String

        @Option(name: .long, help: "Override marketing version (e.g., 2.0). If not specified, uses smart formatting from version.")
        var marketingVersion: String?

        @Option(name: .long, help: "Override build number (e.g., 123, 2.0-beta.1). If not specified, uses the full version.")
        var buildNumber: String?

        @Argument(help: "Path to directory (or container) with Xcode project/workspace.")
        var projectPath: String?

        @Flag(name: .shortAndLong, help: "Show verbose archive output.")
        var verbose = false

        func run() throws {
            let inputPath = self.projectPath ?? FileManager.default.currentDirectoryPath
            let projectType = try DevProjectResolver.determineProjectType(at: inputPath)

            guard case let .xcode(container, scheme) = projectType else {
                throw DevError.invalidInput("Archiving is not supported for Swift packages.")
            }

            let finalMarketingVersion: String
            let finalBuildNumber: String

            if let marketingVersion, let buildNumber {
                finalMarketingVersion = marketingVersion
                finalBuildNumber = buildNumber
            } else if let marketingVersion {
                finalMarketingVersion = marketingVersion
                finalBuildNumber = self.version
            } else if let buildNumber {
                finalMarketingVersion = VersionFormatter.extractBaseVersion(from: self.version)
                finalBuildNumber = buildNumber
            } else {
                let parsed = VersionFormatter.parseVersionForArchive(marketingVersion: self.version, buildNumber: nil)
                finalMarketingVersion = parsed.marketingVersion
                finalBuildNumber = parsed.buildNumber
            }

            SwiftDeploy.printInfo("Archiving \(scheme) (MARKETING_VERSION=\(finalMarketingVersion), CURRENT_PROJECT_VERSION=\(finalBuildNumber))")

            let result = try XcodeBuildService.archive(
                .init(
                    container: container,
                    scheme: scheme,
                    configuration: "Release",
                    destination: nil,
                    derivedDataPath: nil,
                    allowProvisioningUpdates: false,
                    buildSettingsOverrides: [
                        "MARKETING_VERSION": finalMarketingVersion,
                        "CURRENT_PROJECT_VERSION": finalBuildNumber,
                    ],
                ),
                verbose: self.verbose,
            )

            guard result.success else {
                throw DevError.buildFailed("Archive failed with exit code \(result.terminationStatus)")
            }

            SwiftDeploy.printInfo("Archive complete. Use Xcode Organizer for distribution.")
        }
    }
}

// MARK: - SwiftDeploy.Dev.Prepare

extension SwiftDeploy.Dev {
    struct Prepare: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "prepare",
            abstract: "Prepare release packages (DMG and zip) from an exported archived app in ~/Downloads.",
        )

        @Argument(help: "Version for the release packages (e.g., 1.2.3).")
        var version: String

        @Argument(help: "Path to directory (or container) with Xcode project/workspace.")
        var projectPath: String?

        @Flag(name: .long, help: "Install the app to /Applications after creating packages.")
        var install = false

        func run() throws {
            let inputPath = self.projectPath ?? FileManager.default.currentDirectoryPath
            let projectType = try DevProjectResolver.determineProjectType(at: inputPath)

            guard case let .xcode(_, scheme) = projectType else {
                throw DevError.invalidInput("Release preparation is not supported for Swift packages.")
            }

            try ReleasePackager.prepareFromDownloads(
                projectName: scheme,
                version: self.version,
                shouldInstallToApplications: self.install,
            )
        }
    }
}

// MARK: - SwiftDeploy.Dev.Link

extension SwiftDeploy.Dev {
    struct Link: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "link",
            abstract: "Build and create a symlink in ~/.local/bin for the runnable executable.",
        )

        @Argument(help: "Path to directory (or container) with Xcode project/workspace or Package.swift.")
        var projectPath: String?

        @Option(name: .shortAndLong, help: "Target name for Swift packages with multiple executables.")
        var target: String?

        func run() throws {
            let inputPath = self.projectPath ?? FileManager.default.currentDirectoryPath
            let projectType = try DevProjectResolver.determineProjectType(at: inputPath)

            try DevBuildOrchestrator.build(projectType: projectType, configuration: "Debug")
            let exec = try DevBuildOrchestrator.executableInfo(projectType: projectType, targetName: self.target)
            try DevBuildOrchestrator.createLocalBinSymlink(executablePath: exec.path, executableName: exec.name)
        }
    }
}

// MARK: - DevProjectType

enum DevProjectType: Sendable {
    case xcode(container: XcodeContainerReference, scheme: String)
    case swiftPackage(path: String, name: String)

    var defaultRunName: String {
        switch self {
        case let .xcode(_, scheme): scheme
        case let .swiftPackage(_, name): name
        }
    }
}

// MARK: - DevProjectResolver

enum DevProjectResolver {
    static func determineProjectType(at input: String) throws -> DevProjectType {
        let path = self.normalizeInputPath(input)

        if path.hasSuffix(".xcworkspace") {
            let container = XcodeContainerReference.workspace(path)
            let scheme = XcodeBuildService.detectScheme(container: container)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return .xcode(container: container, scheme: scheme)
        }

        if path.hasSuffix(".xcodeproj") {
            let container = XcodeContainerReference.project(path)
            let scheme = XcodeBuildService.detectScheme(container: container)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return .xcode(container: container, scheme: scheme)
        }

        // Prefer workspace over project if both exist in the directory.
        if let container = findXcodeContainer(in: path) {
            let scheme = XcodeBuildService.detectScheme(container: container)
                ?? URL(fileURLWithPath: container.path).deletingPathExtension().lastPathComponent
            return .xcode(container: container, scheme: scheme)
        }

        let packageSwiftPath = "\(path)/Package.swift"
        if FileManager.default.fileExists(atPath: packageSwiftPath) {
            guard let name = extractPackageName(from: packageSwiftPath) else {
                throw DevError.invalidInput("Found Package.swift but couldn't extract package name.")
            }
            return .swiftPackage(path: path, name: name)
        }

        throw DevError.invalidInput("No Xcode project/workspace or Package.swift found at \(path)")
    }

    private static func normalizeInputPath(_ input: String) -> String {
        var p = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty {
            p = FileManager.default.currentDirectoryPath
        }
        if p.hasPrefix("~/") {
            p = NSHomeDirectory() + String(p.dropFirst(1))
        }
        return p
    }

    private static func findXcodeContainer(in directory: String) -> XcodeContainerReference? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return .workspace("\(directory)/\(workspace)")
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return .project("\(directory)/\(project)")
        }
        return nil
    }

    private static func extractPackageName(from packageSwiftPath: String) -> String? {
        guard let content = try? String(contentsOfFile: packageSwiftPath, encoding: .utf8) else {
            return nil
        }

        let pattern = #"name:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range) else {
            return nil
        }

        guard let nameRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return String(content[nameRange])
    }
}

// MARK: - DevBuildOrchestrator

enum DevBuildOrchestrator {
    static func build(projectType: DevProjectType, configuration: String) throws {
        switch projectType {
        case let .xcode(container, scheme):
            SwiftDeploy.printInfo("Building Xcode \(container.kind == .workspace ? "workspace" : "project"): \(scheme)")
            let result = try XcodeBuildService.build(
                .init(
                    container: container,
                    scheme: scheme,
                    configuration: configuration,
                    destination: nil,
                    derivedDataPath: nil,
                    allowProvisioningUpdates: false,
                    buildSettingsOverrides: [:],
                ),
                verbose: true,
            )
            guard result.success else {
                throw DevError.buildFailed("Xcode build failed with exit code \(result.terminationStatus)")
            }

        case let .swiftPackage(path, name):
            SwiftDeploy.printInfo("Building Swift package: \(name)")
            try SwiftPMService.build(packagePath: path, configuration: configuration)
        }
    }

    static func run(
        projectType: DevProjectType,
        configuration: String,
        targetName: String?,
        runArguments: [String],
    ) throws {
        switch projectType {
        case let .xcode(_, scheme):
            guard
                let exec = AppLocator.locateRunnableExecutable(
                    productName: scheme,
                    configuration: configuration,
                    derivedDataPath: nil,
                ) else
            {
                throw DevError.buildFailed("Could not find built executable for \(scheme).")
            }

            SwiftDeploy.printInfo("Running: \(exec)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exec)
            process.arguments = runArguments
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            process.standardInput = FileHandle.standardInput
            try process.run()
            process.waitUntilExit()

        case let .swiftPackage(path, _):
            let executables = try SwiftPMService.findExecutables(packagePath: path)
            switch executables.count {
            case 0:
                throw DevError.buildFailed("No executable targets found in Swift package.")

            case 1:
                let target = targetName ?? executables[0]
                if let specified = targetName, !executables.contains(specified) {
                    throw DevError.invalidInput("Executable '\(specified)' not found. Available: \(executables.joined(separator: ", "))")
                }
                try SwiftPMService.run(packagePath: path, target: target, configuration: configuration, runArguments: runArguments)

            default:
                if let specified = targetName {
                    guard executables.contains(specified) else {
                        throw DevError.invalidInput("Executable '\(specified)' not found. Available: \(executables.joined(separator: ", "))")
                    }
                    try SwiftPMService.run(packagePath: path, target: specified, configuration: configuration, runArguments: runArguments)
                } else {
                    throw DevError.invalidInput(
                        "Multiple executables found: \(executables.joined(separator: ", ")). Specify one with --target.",
                    )
                }
            }
        }
    }

    static func executableInfo(projectType: DevProjectType, targetName: String?) throws -> (path: String, name: String) {
        switch projectType {
        case let .xcode(_, scheme):
            guard let exec = AppLocator.locateRunnableExecutable(productName: scheme, configuration: "Debug", derivedDataPath: nil) else {
                throw DevError.buildFailed("Could not find built executable for \(scheme).")
            }
            return (exec, scheme)

        case let .swiftPackage(path, _):
            let executables = try SwiftPMService.findExecutables(packagePath: path)

            func spmPath(for name: String) -> String {
                let debug = "\(path)/.build/debug/\(name)"
                let release = "\(path)/.build/release/\(name)"
                if FileManager.default.fileExists(atPath: debug) { return debug }
                if FileManager.default.fileExists(atPath: release) { return release }
                return debug
            }

            switch executables.count {
            case 0:
                throw DevError.buildFailed("No executable targets found in Swift package.")

            case 1:
                let target = targetName ?? executables[0]
                if let specified = targetName, !executables.contains(specified) {
                    throw DevError.invalidInput("Executable '\(specified)' not found. Available: \(executables.joined(separator: ", "))")
                }
                return (spmPath(for: target), target)

            default:
                if let specified = targetName {
                    guard executables.contains(specified) else {
                        throw DevError.invalidInput("Executable '\(specified)' not found. Available: \(executables.joined(separator: ", "))")
                    }
                    return (spmPath(for: specified), specified)
                }
                throw DevError.invalidInput(
                    "Multiple executables found: \(executables.joined(separator: ", ")). Specify one with --target.",
                )
            }
        }
    }

    static func createLocalBinSymlink(executablePath: String, executableName: String) throws {
        let home = NSHomeDirectory()
        let localBin = "\(home)/.local/bin"
        let fm = FileManager.default

        if !fm.fileExists(atPath: localBin) {
            try fm.createDirectory(atPath: localBin, withIntermediateDirectories: true)
            SwiftDeploy.printInfo("Created directory: \(localBin)")
        }

        let symlinkPath = "\(localBin)/\(executableName)"
        if fm.fileExists(atPath: symlinkPath) {
            try fm.removeItem(atPath: symlinkPath)
        }

        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: symlinkPath)

        SwiftDeploy.printInfo("Linked \(symlinkPath) -> \(executablePath)")
    }

    static func killExistingProcess(named processName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-x", processName]
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - VersionFormatter

enum VersionFormatter {
    static func parseVersionForArchive(marketingVersion: String, buildNumber: String?) -> (marketingVersion: String, buildNumber: String) {
        if let buildNumber {
            return (self.extractBaseVersion(from: marketingVersion), buildNumber)
        }
        return (self.extractBaseVersion(from: marketingVersion), marketingVersion)
    }

    static func extractBaseVersion(from version: String) -> String {
        if let plus = version.firstIndex(of: "+") {
            return self.formatPrereleaseVersion(String(version[..<plus]))
        }
        return self.formatPrereleaseVersion(version)
    }

    static func formatPrereleaseVersion(_ version: String) -> String {
        if let dash = version.firstIndex(of: "-") {
            let base = String(version[..<dash])
            let prerelease = String(version[version.index(after: dash)...])
            if prerelease.hasPrefix("rc.") {
                return "\(base)rc\(prerelease.dropFirst(3))"
            }
            let formatted = prerelease.replacingOccurrences(of: ".", with: " ")
            return "\(base) \(formatted)"
        }
        return version
    }
}

// MARK: - DevError

enum DevError: LoggableError {
    case invalidInput(String)
    case buildFailed(String)

    var logMessage: String {
        switch self {
        case let .invalidInput(msg): msg
        case let .buildFailed(msg): msg
        }
    }
}
