import ArgumentParser
import CommonCrypto
import Foundation
import PolyKit

// MARK: - SwiftBuilder

@main
struct SwiftBuilder: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "swbuild",
        abstract: "Build Xcode projects or Swift packages with optional running or archiving.",
        subcommands: [Build.self, Run.self, Archive.self, Prepare.self, Install.self],
        defaultSubcommand: Build.self,
    )

    private static let logger: PolyLog = .init()

    func logAndExit(_ error: some LoggableError) -> Never {
        Self.logger.logAndExit(error)
    }

    func logAndThrow(_ error: some LoggableError) throws {
        try Self.logger.logAndThrow(error)
    }
}

// MARK: - Build

struct Build: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "build",
        abstract: "Build the project.",
    )

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    /// Long-only to avoid collisions with app args.
    @Option(name: .long, help: "Build configuration (Debug or Release).")
    var configuration: String = "Debug"

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.buildForDevelopment(projectType: projectType, configuration: configuration)
    }
}

// MARK: - Run

struct Run: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "run",
        abstract: "Build and run the project.",
    )

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Option(name: .shortAndLong, help: "Target name for Swift packages with multiple executables.")
    var target: String?

    /// Long-only to avoid collisions with app args
    @Option(name: .long, help: "Build configuration (Debug or Release).")
    var configuration: String = "Debug"

    @Flag(name: .long, help: "Kill existing process, build, then run.")
    var restart = false

    /// Pass-through arguments to the built executable (after --)
    @Argument(parsing: .captureForPassthrough, help: "Arguments to pass to the executable.")
    var arguments: [String] = []

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.buildForDevelopment(
            projectType: projectType,
            shouldRun: true,
            targetName: target,
            restart: restart,
            configuration: configuration,
            runArguments: arguments,
        )
    }
}

// MARK: - Archive

struct Archive: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "archive",
        abstract: "Archive the project for release.",
    )

    @Argument(help: "Version for the archive (e.g., 1.2.3, 2.0-rc.1). Used for smart formatting unless overridden by options.")
    var version: String

    @Option(name: .long, help: "Override marketing version (e.g., 2.0). If not specified, uses smart formatting from version.")
    var marketingVersion: String?

    @Option(name: .long, help: "Override build number (e.g., 123, 2.0-beta.1). If not specified, uses the full version.")
    var buildNumber: String?

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)

        // Determine final marketing version and build number
        let finalMarketingVersion: String
        let finalBuildNumber: String

        if let marketingVersion, let buildNumber {
            // Both overridden - use as-is
            finalMarketingVersion = marketingVersion
            finalBuildNumber = buildNumber
        } else if let marketingVersion {
            // Only marketing version overridden - use smart formatting for build number
            finalMarketingVersion = marketingVersion
            finalBuildNumber = version
        } else if let buildNumber {
            // Only build number overridden - use smart formatting for marketing version
            finalMarketingVersion = builder.extractBaseVersion(from: version)
            finalBuildNumber = buildNumber
        } else {
            // Neither overridden - use smart formatting for both
            let (parsedMarketingVersion, parsedBuildNumber) = builder.parseVersionForArchive(marketingVersion: version, buildNumber: nil)
            finalMarketingVersion = parsedMarketingVersion
            finalBuildNumber = parsedBuildNumber
        }

        try builder.archiveForRelease(projectType: projectType, marketingVersion: finalMarketingVersion, buildNumber: finalBuildNumber)
    }
}

// MARK: - Prepare

struct Prepare: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "prepare",
        abstract: "Prepare release packages (DMG and zip) from an archived app.",
    )

    @Argument(help: "Version for the release packages (e.g., 1.2.3).")
    var version: String

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Flag(name: .long, help: "Install the app to /Applications after creating packages.")
    var install = false

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.prepareReleaseForUpload(projectType: projectType, version: version, shouldInstall: install)
    }
}

// MARK: - Install

struct Install: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "install",
        abstract: "Install the built executable by creating a symlink in ~/.local/bin.",
    )

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Option(name: .shortAndLong, help: "Target name for Swift packages with multiple executables.")
    var target: String?

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.installExecutable(projectType: projectType, targetName: target)
    }
}

// MARK: - Build and Process

extension SwiftBuilder {
    /// The type of Xcode container.
    enum XcodeContainerKind {
        case project
        case workspace
    }

    /// The type of project, either an Xcode project/workspace or a Swift package.
    enum ProjectType {
        case xcode(kind: XcodeContainerKind, path: String, scheme: String)
        case swiftPackage(path: String, name: String)
    }

    /// The error type given when building projects.
    enum RuntimeError: LoggableError {
        case invalidProject(String)
        case buildFailed(String)
        case multipleExecutables(String)

        var logMessage: String {
            switch self {
            case let .invalidProject(msg): msg
            case let .buildFailed(msg): msg
            case let .multipleExecutables(msg): msg
            }
        }
    }

    /// Determines the type of project at a given path (either Xcode or Swift).
    ///
    /// - Parameter path: The path to determine the project type for.
    /// - Returns: The type of project.
    func determineProjectType(at path: String) throws -> ProjectType {
        // Prefer workspace over project if both exist
        if let (containerPath, kind) = findXcodeContainer(in: path) {
            let scheme = detectXcodeScheme(kind: kind, containerPath: containerPath)
                ?? URL(fileURLWithPath: containerPath).deletingPathExtension().lastPathComponent
            return .xcode(kind: kind, path: containerPath, scheme: scheme)
        }

        // Check for Swift package
        let packageSwiftPath = "\(path)/Package.swift"
        if FileManager.default.fileExists(atPath: packageSwiftPath) {
            guard let packageName = extractPackageName(from: path) else {
                logAndExit(RuntimeError.invalidProject("Found Package.swift but couldn't extract package name"))
            }
            return .swiftPackage(path: path, name: packageName)
        }

        logAndExit(RuntimeError.invalidProject("No Xcode project/workspace or Package.swift found at \(path)"))
    }

    /// Builds a project for development.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to build.
    ///   - shouldRun: Whether to run the app after building.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    ///   - restart: Whether to kill existing process before running.
    ///   - configuration: Build configuration (Debug/Release).
    ///   - runArguments: Arguments to pass to the executable when running.
    func buildForDevelopment(
        projectType: ProjectType,
        shouldRun: Bool = false,
        targetName: String? = nil,
        restart: Bool = false,
        configuration: String = "Debug",
        runArguments: [String] = [],
    ) throws {
        // Handle killing existing process if restart is requested
        if restart {
            let projectName: String =
                switch projectType {
                case let .xcode(_, _, scheme): scheme
                case let .swiftPackage(_, name): name
                }
            killExistingProcess(named: projectName)
        }

        // Build the project
        switch projectType {
        case let .xcode(kind, path, scheme):
            try buildXcodeProject(containerKind: kind, containerPath: path, scheme: scheme, configuration: configuration)
        case let .swiftPackage(path, name):
            try buildSwiftPackage(packagePath: path, packageName: name, configuration: configuration)
        }

        // Run if requested
        if shouldRun || restart {
            let projectName: String =
                switch projectType {
                case let .xcode(_, _, scheme): scheme
                case let .swiftPackage(_, name): name
                }
            try runBuiltApp(
                projectName: projectName,
                projectType: projectType,
                targetName: targetName,
                configuration: configuration,
                runArguments: runArguments,
            )
        }
    }

    /// Archives a project for release. This prepares a project to be validated and distributed.
    /// Note that actual distribution must still be done within the Organizer in Xcode.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to archive.
    ///   - marketingVersion: The marketing version to archive the project with.
    ///   - buildNumber: The build number to archive the project with.
    func archiveForRelease(projectType: ProjectType, marketingVersion: String, buildNumber: String) throws {
        switch projectType {
        case let .xcode(kind, path, scheme):
            try archiveXcodeProject(containerKind: kind, containerPath: path, scheme: scheme, marketingVersion: marketingVersion, buildNumber: buildNumber)
        case .swiftPackage:
            logAndExit(RuntimeError.buildFailed("Archiving is not supported for Swift packages. Use 'swift build -c release' instead."))
        }
    }

    /// Prepares release packages (DMG and zip) from an archived app.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to prepare.
    ///   - version: The version for the release packages.
    ///   - shouldInstall: Whether to install the app to /Applications after creating packages.
    func prepareReleaseForUpload(projectType: ProjectType, version: String, shouldInstall: Bool = false) throws {
        switch projectType {
        case let .xcode(_, _, scheme):
            try prepareXcodeProjectRelease(projectName: scheme, version: version, shouldInstall: shouldInstall)
        case .swiftPackage:
            logAndExit(RuntimeError.buildFailed("Release preparation is not supported for Swift packages. Only Xcode projects can be packaged."))
        }
    }

    /// Installs the built executable by creating a symlink in `~/.local/bin`.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to install.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    func installExecutable(projectType: ProjectType, targetName: String?) throws {
        // First, ensure the project is built
        try buildForDevelopment(projectType: projectType)

        // Get the executable path and name
        let (executablePath, executableName) = try getExecutableInfo(
            projectType: projectType,
            targetName: targetName,
        )

        // Create ~/.local/bin directory if it doesn't exist
        let homeDirectory = NSHomeDirectory()
        let localBinPath = "\(homeDirectory)/.local/bin"
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: localBinPath) {
            try fileManager.createDirectory(atPath: localBinPath, withIntermediateDirectories: true)
            PolyText.printColor("Created directory: \(localBinPath)", .green)
        }

        // Create the symlink
        let symlinkPath = "\(localBinPath)/\(executableName)"

        // Remove existing symlink if it exists
        if fileManager.fileExists(atPath: symlinkPath) {
            try fileManager.removeItem(atPath: symlinkPath)
        }

        // Create the symlink
        try fileManager.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
        PolyText.printColor("Created symlink: \(symlinkPath) -> \(executablePath)", .green)

        // Make the symlink executable
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try fileManager.setAttributes(attributes, ofItemAtPath: symlinkPath)

        PolyText.printColor("\nInstallation complete! You can now run '\(executableName)' from anywhere.", .green)
    }

    /// Gets the executable path and name for a project.
    ///
    /// - Parameters:
    ///   - projectType: The type of project.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    /// - Returns: A tuple containing the executable path and name.
    func getExecutableInfo(projectType: ProjectType, targetName: String?) throws -> (path: String, name: String) {
        switch projectType {
        case let .xcode(_, _, scheme):
            guard let appPath = findBuiltApp(projectName: scheme) else {
                logAndExit(RuntimeError.buildFailed("Could not find built app for \(scheme)."))
            }
            return (appPath, scheme)

        case let .swiftPackage(path, _):
            let executables = try findSwiftPackageExecutables(at: path)

            func firstExistingSPMPath(for name: String) -> String {
                let debugPath = "\(path)/.build/debug/\(name)"
                let releasePath = "\(path)/.build/release/\(name)"
                if FileManager.default.fileExists(atPath: debugPath) { return debugPath }
                if FileManager.default.fileExists(atPath: releasePath) { return releasePath }
                // Default to debug path if neither exists yet
                return debugPath
            }

            switch executables.count {
            case 0:
                logAndExit(RuntimeError.buildFailed("No executable targets found in Swift package."))

            case 1:
                let target = targetName ?? executables[0]
                if let specifiedTarget = targetName, !executables.contains(specifiedTarget) {
                    logAndExit(RuntimeError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                }
                return (firstExistingSPMPath(for: target), target)

            default:
                if let specifiedTarget = targetName {
                    if executables.contains(specifiedTarget) {
                        return (firstExistingSPMPath(for: specifiedTarget), specifiedTarget)
                    } else {
                        logAndExit(RuntimeError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                    }
                } else {
                    let executableList = executables.joined(separator: ", ")
                    logAndExit(RuntimeError.multipleExecutables(
                        "Multiple executables found:\n \(executableList)\n\nPlease specify which to install: swbuild install --target <executable-name>"))
                }
            }
        }
    }

    /// Prepares DMG and zip packages for an Xcode project.
    ///
    /// - Parameters:
    ///   - projectName: The name of the project.
    ///   - version: The version for the packages.
    ///   - shouldInstall: Whether to install the app to /Applications after creating packages.
    func prepareXcodeProjectRelease(projectName: String, version: String, shouldInstall: Bool = false) throws {
        PolyText.printColor("Preparing release packages for \(projectName) \(version)...", .green)

        // Define paths
        let homeDirectory = NSHomeDirectory()
        let appPath = "\(homeDirectory)/Downloads/\(projectName).app"
        let outputPath = "\(homeDirectory)/Developer/\(projectName)/releases"

        // Check if the app exists in Downloads
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appPath) else {
            logAndExit(RuntimeError.buildFailed("App not found at \(appPath). Please ensure the app is exported to ~/Downloads."))
        }

        // Create output directory if needed
        try fileManager.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        // Create DMG
        PolyText.printColor("Creating DMG file...", .green)
        let dmgPath = "\(outputPath)/\(projectName)-\(version).dmg"
        try createDMG(
            appPath: appPath,
            outputPath: dmgPath,
            volumeName: projectName,
        )

        // Calculate and display SHA256 hash for Homebrew
        PolyText.printColor("Calculating SHA256 hash...", .green)
        let sha256Hash = try calculateSHA256Hash(for: dmgPath)

        // Create zip
        PolyText.printColor("Creating zip file...", .green)
        try createZip(
            appPath: appPath,
            outputPath: "\(outputPath)/\(projectName)-\(version).zip",
        )

        // Install to /Applications if requested
        if shouldInstall {
            try installAppToApplications(appPath: appPath, appName: projectName)
            // Clean up the original app from Downloads since it's now installed
            try cleanupOriginalApp(from: appPath)
        }

        // Open the releases folder
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [outputPath]
        try openProcess.run()

        PolyText.printColor("Release packages created successfully: \(outputPath)", .green)
        PolyText.printColor("SHA256: \(sha256Hash)", .cyan)
    }

    /// Calculates the SHA256 hash of a file.
    ///
    /// - Parameter filePath: The path to the file to hash.
    /// - Returns: The SHA256 hash as a hexadecimal string.
    func calculateSHA256Hash(for filePath: String) throws -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: fileURL)

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { bytes in
            CC_SHA256(bytes.bindMemory(to: UInt8.self).baseAddress, CC_LONG(data.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Installs an app bundle to /Applications, overwriting any existing version.
    ///
    /// - Parameters:
    ///   - appPath: The path to the .app bundle to install.
    ///   - appName: The name of the app (without .app extension).
    func installAppToApplications(appPath: String, appName: String) throws {
        PolyText.printColor("Installing \(appName) to /Applications...", .green)

        let fileManager = FileManager.default
        let destinationPath = "/Applications/\(appName).app"

        // Remove existing app if it exists
        if fileManager.fileExists(atPath: destinationPath) {
            PolyText.printColor("Removing existing \(appName) from /Applications...", .yellow)
            try fileManager.removeItem(atPath: destinationPath)
        }

        // Copy the app to /Applications
        try fileManager.copyItem(atPath: appPath, toPath: destinationPath)

        // Set proper permissions
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try fileManager.setAttributes(attributes, ofItemAtPath: destinationPath)

        PolyText.printColor("\(appName) installed successfully to /Applications!", .green)
    }

    /// Cleans up the original app from Downloads after installation.
    ///
    /// - Parameter appPath: The path to the original app bundle to remove.
    func cleanupOriginalApp(from appPath: String) throws {
        let fileManager = FileManager.default

        // Only clean up if the app exists
        guard fileManager.fileExists(atPath: appPath) else {
            return // Nothing to clean up
        }

        PolyText.printColor("Cleaning up original app from Downloads...", .green)
        try fileManager.removeItem(atPath: appPath)
        PolyText.printColor("Original app removed from Downloads.", .green)
    }

    /// Creates a DMG image from an app.
    ///
    /// - Parameters:
    ///   - appPath: The path to the .app bundle.
    ///   - outputPath: The path where the DMG should be created.
    ///   - volumeName: The name for the DMG volume.
    func createDMG(appPath: String, outputPath: String, volumeName: String) throws {
        let hdiutilProcess = Process()
        hdiutilProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutilProcess.arguments = [
            "create",
            "-volname",
            volumeName,
            "-srcfolder",
            appPath,
            "-ov",
            "-format",
            "UDZO",
            outputPath,
        ]

        try hdiutilProcess.run()
        hdiutilProcess.waitUntilExit()

        guard hdiutilProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("DMG creation failed with exit code \(hdiutilProcess.terminationStatus)"))
        }
    }

    /// Creates a zip file from an app.
    ///
    /// - Parameters:
    ///   - appPath: The path to the .app bundle.
    ///   - outputPath: The path where the zip file should be created.
    func createZip(appPath: String, outputPath: String) throws {
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            appPath,
            outputPath,
        ]

        try dittoProcess.run()
        dittoProcess.waitUntilExit()

        guard dittoProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Zip creation failed with exit code \(dittoProcess.terminationStatus)"))
        }
    }

    /// Builds an Xcode project or workspace.
    ///
    /// - Parameters:
    ///   - containerKind: Whether this is a project or workspace.
    ///   - containerPath: The .xcodeproj or .xcworkspace path.
    ///   - scheme: The scheme to build.
    ///   - configuration: Debug or Release.
    func buildXcodeProject(containerKind: XcodeContainerKind, containerPath: String, scheme: String, configuration: String) throws {
        let configText = configuration == "Debug" ? "" : " [Release]"
        PolyText.printColor("Building Xcode \(containerKind == .workspace ? "workspace" : "project"): \(scheme)\(configText)", .green)

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild"]
        switch containerKind {
        case .project:
            args += ["-project", containerPath]
        case .workspace:
            args += ["-workspace", containerPath]
        }
        args += ["-scheme", scheme, "-configuration", configuration, "build"]
        buildProcess.arguments = args

        // Stream output directly
        buildProcess.standardOutput = FileHandle.standardOutput
        buildProcess.standardError = FileHandle.standardError

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Xcode build failed with exit code \(buildProcess.terminationStatus)"))
        }

        PolyText.printColor("Build completed successfully!", .green)
    }

    /// Builds a Swift package.
    ///
    /// - Parameters:
    ///   - packagePath: The path to the Swift package.
    ///   - packageName: The name of the Swift package.
    ///   - configuration: Debug or Release.
    func buildSwiftPackage(packagePath: String, packageName: String, configuration: String) throws {
        let configText = configuration == "Debug" ? "" : " [Release]"
        PolyText.printColor("Building Swift package: \(packageName)\(configText)", .green)

        let swiftpmConfig = configuration.lowercased()
        guard swiftpmConfig == "debug" || swiftpmConfig == "release" else {
            logAndExit(RuntimeError.buildFailed("Invalid SwiftPM configuration '\(configuration)'. Use Debug or Release."))
        }

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["build", "-c", swiftpmConfig]
        buildProcess.currentDirectoryPath = packagePath

        // Stream output directly
        buildProcess.standardOutput = FileHandle.standardOutput
        buildProcess.standardError = FileHandle.standardError

        try buildProcess.run()
        buildProcess.waitUntilExit()

        guard buildProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Swift build failed with exit code \(buildProcess.terminationStatus)"))
        }

        PolyText.printColor("Build completed successfully!", .green)
    }

    /// Archives an Xcode project/workspace for release.
    ///
    /// - Parameters:
    ///   - containerKind: Whether this is a project or workspace.
    ///   - containerPath: The .xcodeproj or .xcworkspace path.
    ///   - scheme: The scheme to archive.
    ///   - marketingVersion: The marketing version to archive the project with.
    ///   - buildNumber: The build number to archive the project with.
    func archiveXcodeProject(containerKind: XcodeContainerKind, containerPath: String, scheme: String, marketingVersion: String, buildNumber: String) throws {
        PolyText.printColor("Archiving \(scheme) with marketing version \(marketingVersion) and build number \(buildNumber)...", .green)

        // First, set the version in the project
        try setProjectVersion(projectPath: containerPath, marketingVersion: marketingVersion, buildNumber: buildNumber)

        // Now archive
        let archiveProcess = Process()
        archiveProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild"]
        switch containerKind {
        case .project:
            args += ["-project", containerPath]
        case .workspace:
            args += ["-workspace", containerPath]
        }
        args += ["-scheme", scheme, "-configuration", "Release", "archive"]
        archiveProcess.arguments = args

        // Stream output directly
        archiveProcess.standardOutput = FileHandle.standardOutput
        archiveProcess.standardError = FileHandle.standardError

        try archiveProcess.run()
        archiveProcess.waitUntilExit()

        guard archiveProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Archive failed with exit code \(archiveProcess.terminationStatus)"))
        }

        PolyText.printColor("Archive complete! Now you can use Xcode Organizer for distribution.", .green)
    }

    /// Sets the version of a project.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the project/workspace (we use its parent dir to run agvtool).
    ///   - marketingVersion: The marketing version to set.
    ///   - buildNumber: The build number to set.
    func setProjectVersion(projectPath: String, marketingVersion: String, buildNumber: String) throws {
        PolyText.printColor("Setting marketing version to: \(marketingVersion) and build number to: \(buildNumber)", .green)

        // Check if this is an Apple Generic Versioning project
        if try isAppleGenericVersioningProject(projectPath: projectPath) {
            try setVersionForAppleGenericProject(projectPath: projectPath, marketingVersion: marketingVersion, buildNumber: buildNumber)
        } else {
            try setVersionWithAgvtool(projectPath: projectPath, marketingVersion: marketingVersion, buildNumber: buildNumber)
        }
    }

    /// Checks if the project uses Apple Generic Versioning.
    func isAppleGenericVersioningProject(projectPath: String) throws -> Bool {
        let projectFile = "\(projectPath)/project.pbxproj"
        PolyText.printColor("Looking for project.pbxproj at: \(projectFile)", .cyan)
        let content = try String(contentsOfFile: projectFile, encoding: .utf8)
        return content.contains("VERSIONING_SYSTEM = \"apple-generic\"")
    }

    /// Sets version for Apple Generic Versioning projects by modifying project.pbxproj directly.
    func setVersionForAppleGenericProject(projectPath: String, marketingVersion: String, buildNumber: String) throws {
        PolyText.printColor("Using Apple Generic Versioning - modifying project.pbxproj directly", .cyan)

        let projectFile = "\(projectPath)/project.pbxproj"
        var content = try String(contentsOfFile: projectFile, encoding: .utf8)

        // Update marketing version
        let marketingVersionPattern = #"MARKETING_VERSION = "[^"]*";"#
        let marketingVersionReplacement = "MARKETING_VERSION = \"\(marketingVersion)\";"
        content = content.replacingOccurrences(of: marketingVersionPattern, with: marketingVersionReplacement, options: .regularExpression)

        // Update build number (CURRENT_PROJECT_VERSION)
        let buildNumberPattern = #"CURRENT_PROJECT_VERSION = [^;]*;"#
        let buildNumberReplacement = "CURRENT_PROJECT_VERSION = \(buildNumber);"
        content = content.replacingOccurrences(of: buildNumberPattern, with: buildNumberReplacement, options: .regularExpression)

        // Write the updated content back
        try content.write(toFile: projectFile, atomically: true, encoding: .utf8)

        PolyText.printColor("Successfully updated project.pbxproj.", .green)
    }

    /// Sets version using agvtool for traditional projects.
    func setVersionWithAgvtool(projectPath: String, marketingVersion: String, buildNumber: String) throws {
        PolyText.printColor("Using agvtool for traditional versioning.", .cyan)

        let projectDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path

        // Set marketing version
        let setVersionProcess = Process()
        setVersionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        setVersionProcess.arguments = ["agvtool", "new-marketing-version", marketingVersion]
        setVersionProcess.currentDirectoryPath = projectDir

        try setVersionProcess.run()
        setVersionProcess.waitUntilExit()

        guard setVersionProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Failed to set marketing version '\(marketingVersion)' with exit code \(setVersionProcess.terminationStatus)"))
        }

        // Set build number
        let setBuildProcess = Process()
        setBuildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        setBuildProcess.arguments = ["agvtool", "new-version", "-all", buildNumber]
        setBuildProcess.currentDirectoryPath = projectDir

        try setBuildProcess.run()
        setBuildProcess.waitUntilExit()

        guard setBuildProcess.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Failed to set build number '\(buildNumber)' with exit code \(setBuildProcess.terminationStatus)."))
        }
    }

    /// Parses version strings for archive operations, handling prerelease versions properly.
    ///
    /// - Parameters:
    ///   - marketingVersion: The marketing version string (may contain prerelease identifiers).
    ///   - buildNumber: Optional build number string.
    /// - Returns: A tuple of (marketingVersion, buildNumber) where marketingVersion is agvtool-compatible.
    func parseVersionForArchive(marketingVersion: String, buildNumber: String?) -> (marketingVersion: String, buildNumber: String) {
        // If build number is explicitly provided, use it as-is
        if let buildNumber {
            return (extractBaseVersion(from: marketingVersion), buildNumber)
        }

        // If no build number provided, use the full marketing version as build number
        // and extract base version for marketing version
        return (extractBaseVersion(from: marketingVersion), marketingVersion)
    }

    /// Extracts the base version from a version string, converting prerelease identifiers to marketing format.
    ///
    /// - Parameter version: The version string to parse.
    /// - Returns: The marketing version with prerelease identifiers formatted for display.
    func extractBaseVersion(from version: String) -> String {
        // Handle build metadata like "1.0.0+123" - just remove the + part
        if let plusIndex = version.firstIndex(of: "+") {
            let versionPart = String(version[..<plusIndex])
            return formatPrereleaseVersion(versionPart)
        }

        // Handle prerelease versions
        return formatPrereleaseVersion(version)
    }

    /// Formats a prerelease version for marketing display.
    ///
    /// - Parameter version: The version string to format.
    /// - Returns: The formatted marketing version.
    func formatPrereleaseVersion(_ version: String) -> String {
        // Handle prerelease versions like "2.0-rc.1", "2.0.0-beta.6", etc.
        if let dashIndex = version.firstIndex(of: "-") {
            let baseVersion = String(version[..<dashIndex])
            let prereleasePart = String(version[version.index(after: dashIndex)...])

            // Special handling for RC versions
            if prereleasePart.hasPrefix("rc.") {
                let rcNumber = String(prereleasePart.dropFirst(3)) // Remove "rc."
                return "\(baseVersion)rc\(rcNumber)"
            } else {
                // Replace dots with spaces for other prerelease types
                let formattedPrerelease = prereleasePart.replacingOccurrences(of: ".", with: " ")
                return "\(baseVersion) \(formattedPrerelease)"
            }
        }

        // No prerelease identifiers, return as-is
        return version
    }

    /// Kills an existing process.
    ///
    /// - Parameter processName: The name of the process to kill.
    func killExistingProcess(named processName: String) {
        PolyText.printColor("Killing existing process: \(processName)", .green)

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // -x for exact match; -f is broader and can kill unintended matches
        killProcess.arguments = ["-x", processName]

        // It doesn't matter if this fails since the process might not be running
        try? killProcess.run()
        killProcess.waitUntilExit()
    }

    /// Runs a built app or executable.
    ///
    /// - Parameters:
    ///   - projectName: The name of the project/scheme.
    ///   - projectType: The type of project.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    ///   - configuration: Build configuration (Debug/Release).
    ///   - runArguments: Arguments to pass to the executable.
    func runBuiltApp(
        projectName: String,
        projectType: ProjectType,
        targetName: String? = nil,
        configuration: String = "Debug",
        runArguments: [String] = [],
    ) throws {
        switch projectType {
        case .xcode:
            // Xcode projects typically have one main executable
            guard let appPath = findBuiltApp(projectName: projectName, configuration: configuration) else {
                logAndExit(RuntimeError.buildFailed("Could not find built app/executable for \(projectName)"))
            }

            PolyText.printColor("Running: \(appPath)", .green)

            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: appPath)
            runProcess.arguments = runArguments
            runProcess.standardOutput = FileHandle.standardOutput
            runProcess.standardError = FileHandle.standardError
            runProcess.standardInput = FileHandle.standardInput

            try runProcess.run()
            runProcess.waitUntilExit()

        case let .swiftPackage(path, _):
            // Swift packages can have multiple executables, so identify or ask
            let executables = try findSwiftPackageExecutables(at: path)

            switch executables.count {
            case 0:
                logAndExit(RuntimeError.buildFailed("No executable targets found in Swift package."))

            case 1:
                let target = targetName ?? executables[0]
                if let specifiedTarget = targetName, !executables.contains(specifiedTarget) {
                    logAndExit(RuntimeError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                }
                PolyText.printColor("Running Swift package executable: \(target)", .green)
                try runSwiftPackageTarget(at: path, target: target, configuration: configuration, runArguments: runArguments)

            default:
                if let specifiedTarget = targetName {
                    if executables.contains(specifiedTarget) {
                        PolyText.printColor("Running Swift package executable: \(specifiedTarget)", .green)
                        try runSwiftPackageTarget(at: path, target: specifiedTarget, configuration: configuration, runArguments: runArguments)
                    } else {
                        logAndExit(RuntimeError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                    }
                } else {
                    let executableList = executables.joined(separator: ", ")
                    logAndExit(RuntimeError.multipleExecutables(
                        "Multiple executables found:\n \(executableList)\n\nPlease specify which to run: swbuild run --target <executable-name>"))
                }
            }
        }
    }

    /// Checks if a path is a Swift package.
    ///
    /// - Parameter path: The path to check.
    func isSwiftPackage(in path: String) -> Bool {
        let packageSwiftPath = "\(path)/Package.swift"
        return FileManager.default.fileExists(atPath: packageSwiftPath)
    }

    /// Extracts the name of a Swift package from a path.
    ///
    /// - Parameter path: The path to extract the package name from.
    func extractPackageName(from path: String) -> String? {
        let packageSwiftPath = "\(path)/Package.swift"
        do {
            let content = try String(contentsOfFile: packageSwiftPath, encoding: .utf8)

            // Create the regex pattern
            let pattern = #"name:\s*"([^"]+)""#
            let regex = try NSRegularExpression(pattern: pattern)

            // Find the first match
            let range = NSRange(content.startIndex..., in: content)
            if let match = regex.firstMatch(in: content, range: range) {
                // Extract the captured group
                if let nameRange = Range(match.range(at: 1), in: content) {
                    return String(content[nameRange])
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Finds all executable products or targets using `swift package dump-package`.
    ///
    /// - Parameter path: The path to the Swift package directory.
    /// - Returns: An array of executable product names (falls back to executable target names if needed).
    func findSwiftPackageExecutables(at path: String) throws -> [String] {
        let dump = Process()
        dump.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        dump.arguments = ["package", "dump-package"]
        dump.currentDirectoryPath = path

        let outPipe = Pipe()
        dump.standardOutput = outPipe
        dump.standardError = Pipe()

        try dump.run()
        dump.waitUntilExit()

        guard dump.terminationStatus == 0 else {
            logAndExit(RuntimeError.buildFailed("Failed to dump package manifest (exit code \(dump.terminationStatus)."))
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return []
        }

        struct DumpPackage: Decodable {
            struct Product: Decodable {
                struct ProductType: Decodable {
                    // In dump-package JSON, type is an object with a single key indicating the type
                    // We model common possibilities as optional arrays (values may be null or arrays)
                    let executable: [String]?
                    let library: [String]?
                    let test: [String]?
                    let plugin: [String]?
                    let macro: [String]?

                    var isExecutable: Bool { executable != nil }
                }

                let name: String
                let type: ProductType
            }

            struct Target: Decodable {
                let name: String
                let type: String? // "executable", "library", etc.
            }

            let products: [Product]?
            let targets: [Target]?
        }

        let decoder = JSONDecoder()
        let manifest: DumpPackage
        do {
            manifest = try decoder.decode(DumpPackage.self, from: data)
        } catch {
            logAndExit(RuntimeError.buildFailed("Could not parse dump-package JSON: \(error)"))
        }

        // Prefer executable products
        var names = [String]()
        if let products = manifest.products {
            for product in products where product.type.isExecutable {
                names.append(product.name)
            }
        }

        // Fallback to executable targets if no executable products were found
        if names.isEmpty, let targets = manifest.targets {
            for target in targets where target.type == "executable" {
                if !names.contains(target.name) {
                    names.append(target.name)
                }
            }
        }

        return names
    }

    /// Runs a specific executable target/product in a Swift package.
    ///
    /// - Parameters:
    ///   - path: The path to the Swift package directory.
    ///   - target: The name of the executable target/product to run.
    ///   - configuration: The build configuration to use.
    ///   - runArguments: Arguments to pass to the executable.
    func runSwiftPackageTarget(at path: String, target: String, configuration: String, runArguments: [String]) throws {
        let swiftpmConfig = configuration.lowercased()
        guard swiftpmConfig == "debug" || swiftpmConfig == "release" else {
            logAndExit(RuntimeError.buildFailed("Invalid SwiftPM configuration '\(configuration)'. Use Debug or Release."))
        }

        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        // Pass configuration and target/product, then "--" and arguments
        var args = ["run", "-c", swiftpmConfig, target]
        if !runArguments.isEmpty {
            args.append("--")
            args.append(contentsOf: runArguments)
        }
        runProcess.arguments = args
        runProcess.currentDirectoryPath = path

        runProcess.standardOutput = FileHandle.standardOutput
        runProcess.standardError = FileHandle.standardError
        runProcess.standardInput = FileHandle.standardInput

        try runProcess.run()
        runProcess.waitUntilExit()
    }

    /// Finds an Xcode project/workspace in a path, preferring workspace.
    ///
    /// - Parameter path: The path to search.
    /// - Returns: (path, kind) if found.
    func findXcodeContainer(in path: String = FileManager.default.currentDirectoryPath) -> (String, XcodeContainerKind)? {
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                return ("\(path)/\(workspace)", .workspace)
            }
            if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                return ("\(path)/\(project)", .project)
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Attempts to detect an appropriate scheme for the given container using xcodebuild -list -json.
    ///
    /// - Parameters:
    ///   - kind: Whether this is a project or workspace.
    ///   - containerPath: The .xcodeproj or .xcworkspace path.
    /// - Returns: A scheme name if detected.
    func detectXcodeScheme(kind: XcodeContainerKind, containerPath: String) -> String? {
        let listProcess = Process()
        listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var args = ["xcodebuild", "-list", "-json"]
        switch kind {
        case .project:
            args += ["-project", containerPath]
        case .workspace:
            args += ["-workspace", containerPath]
        }
        listProcess.arguments = args

        let pipe = Pipe()
        listProcess.standardOutput = pipe
        listProcess.standardError = Pipe()

        do {
            try listProcess.run()
        } catch {
            return nil
        }

        listProcess.waitUntilExit()
        guard listProcess.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }

        struct XcodeContainerInfo: Decodable {
            let name: String?
            let schemes: [String]?
        }
        struct XcodeListOutput: Decodable {
            let project: XcodeContainerInfo?
            let workspace: XcodeContainerInfo?
        }

        guard let output = try? JSONDecoder().decode(XcodeListOutput.self, from: data) else {
            return nil
        }

        let schemes = (kind == .project ? output.project?.schemes : output.workspace?.schemes) ?? []
        if schemes.isEmpty { return nil }

        // Prefer a scheme that matches the container name, otherwise just the first scheme
        let baseName = URL(fileURLWithPath: containerPath).deletingPathExtension().lastPathComponent
        if let matching = schemes.first(where: { $0 == baseName }) {
            return matching
        }
        return schemes.first
    }

    /// Finds a built app or CLI executable in DerivedData or local build directories.
    ///
    /// - Parameters:
    ///   - projectName: The name of the scheme/product.
    ///   - configuration: Build configuration (Debug/Release).
    /// - Returns: The path to the built binary to execute.
    func findBuiltApp(projectName: String, configuration: String = "Debug") -> String? {
        let derivedDataPath = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
        let fileManager = FileManager.default

        // Search in DerivedData for both app bundle executables and CLI products
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: derivedDataPath)
            for item in contents where item.contains(projectName) {
                let appExecPath = "\(derivedDataPath)/\(item)/Build/Products/\(configuration)/\(projectName).app/Contents/MacOS/\(projectName)"
                if fileManager.fileExists(atPath: appExecPath) {
                    return appExecPath
                }
                let cliExecPath = "\(derivedDataPath)/\(item)/Build/Products/\(configuration)/\(projectName)"
                if fileManager.fileExists(atPath: cliExecPath) {
                    return cliExecPath
                }
            }
        } catch {
            // Continue to fallback
        }

        // Fallback to local SPM-style build directories
        let currentDirectory = FileManager.default.currentDirectoryPath
        let localBuildPaths = [
            "\(currentDirectory)/.build/\(configuration.lowercased())/\(projectName)",
            "\(currentDirectory)/build/\(configuration.lowercased())/\(projectName)",
        ]

        for buildPath in localBuildPaths where fileManager.fileExists(atPath: buildPath) {
            return buildPath
        }

        return nil
    }
}
