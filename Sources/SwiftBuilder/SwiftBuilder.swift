import ArgumentParser
import CommonCrypto
import Foundation
import Polykit

// MARK: - SwiftBuilder

@main
struct SwiftBuilder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swbuild",
        abstract: "Build Xcode projects or Swift packages with optional running or archiving.",
        subcommands: [Build.self, Run.self, Archive.self, Prepare.self, Install.self],
        defaultSubcommand: Build.self,
    )

    private static let logger = PolyLog(simple: true)
}

// MARK: - Build

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the project.",
    )

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    // Long-only to avoid collisions with app args.
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
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run the project.",
    )

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Option(name: .shortAndLong, help: "Target name for Swift packages with multiple executables.")
    var target: String?

    // Long-only to avoid collisions with app args
    @Option(name: .long, help: "Build configuration (Debug or Release).")
    var configuration: String = "Debug"

    @Flag(name: .long, help: "Kill existing process, build, then run.")
    var restart = false

    // Pass-through arguments to the built executable (after --)
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
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Archive the project for release.",
    )

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Argument(help: "Version for the archive (e.g., 1.2.3).")
    var version: String

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.archiveForRelease(projectType: projectType, version: version)
    }
}

// MARK: - Prepare

struct Prepare: ParsableCommand {
    static let configuration = CommandConfiguration(
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
    static let configuration = CommandConfiguration(
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
    enum BuildError: LoggableError {
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

        var isWarning: Bool {
            switch self {
            case .multipleExecutables: true
            default: false
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
                Self.logger.logAndExit(BuildError.invalidProject("Found Package.swift but couldn't extract package name"))
            }
            return .swiftPackage(path: path, name: packageName)
        }

        Self.logger.logAndExit(BuildError.invalidProject("No Xcode project/workspace or Package.swift found at \(path)"))
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
    ///   - version: The version to archive the project with.
    func archiveForRelease(projectType: ProjectType, version: String) throws {
        switch projectType {
        case let .xcode(kind, path, scheme):
            try archiveXcodeProject(containerKind: kind, containerPath: path, scheme: scheme, version: version)
        case .swiftPackage:
            Self.logger.logAndExit(BuildError.buildFailed("Archiving is not supported for Swift packages. Use 'swift build -c release' instead."))
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
            Self.logger.logAndExit(BuildError.buildFailed("Release preparation is not supported for Swift packages. Only Xcode projects can be packaged."))
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
            Text.printColor("Created directory: \(localBinPath)", .green)
        }

        // Create the symlink
        let symlinkPath = "\(localBinPath)/\(executableName)"

        // Remove existing symlink if it exists
        if fileManager.fileExists(atPath: symlinkPath) {
            try fileManager.removeItem(atPath: symlinkPath)
        }

        // Create the symlink
        try fileManager.createSymbolicLink(atPath: symlinkPath, withDestinationPath: executablePath)
        Text.printColor("Created symlink: \(symlinkPath) -> \(executablePath)", .green)

        // Make the symlink executable
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try fileManager.setAttributes(attributes, ofItemAtPath: symlinkPath)

        Text.printColor("\nInstallation complete! You can now run '\(executableName)' from anywhere.", .green)
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
                Self.logger.logAndExit(BuildError.buildFailed("Could not find built app for \(scheme)."))
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
                Self.logger.logAndExit(BuildError.buildFailed("No executable targets found in Swift package."))
            case 1:
                let target = targetName ?? executables[0]
                if let specifiedTarget = targetName, !executables.contains(specifiedTarget) {
                    Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                }
                return (firstExistingSPMPath(for: target), target)
            default:
                if let specifiedTarget = targetName {
                    if executables.contains(specifiedTarget) {
                        return (firstExistingSPMPath(for: specifiedTarget), specifiedTarget)
                    } else {
                        Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                    }
                } else {
                    let executableList = executables.joined(separator: ", ")
                    Self.logger.logAndExit(BuildError.multipleExecutables(
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
        Text.printColor("Preparing release packages for \(projectName) \(version)...", .green)

        // Define paths
        let homeDirectory = NSHomeDirectory()
        let appPath = "\(homeDirectory)/Downloads/\(projectName).app"
        let outputPath = "\(homeDirectory)/Developer/\(projectName)/releases"

        // Check if the app exists in Downloads
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appPath) else {
            Self.logger.logAndExit(BuildError.buildFailed("App not found at \(appPath). Please ensure the app is exported to ~/Downloads."))
        }

        // Create output directory if needed
        try fileManager.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        // Create DMG
        Text.printColor("Creating DMG file...", .green)
        let dmgPath = "\(outputPath)/\(projectName)-\(version).dmg"
        try createDMG(
            appPath: appPath,
            outputPath: dmgPath,
            volumeName: projectName,
        )

        // Calculate and display SHA256 hash for Homebrew
        Text.printColor("Calculating SHA256 hash...", .green)
        let sha256Hash = try calculateSHA256Hash(for: dmgPath)

        // Create zip
        Text.printColor("Creating zip file...", .green)
        try createZip(
            appPath: appPath,
            outputPath: "\(outputPath)/\(projectName)-\(version).zip",
        )

        // Install to /Applications if requested
        if shouldInstall {
            try installAppToApplications(appPath: appPath, appName: projectName)
        }

        // Open the releases folder
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [outputPath]
        try openProcess.run()

        Text.printColor("Release packages created successfully: \(outputPath)", .green)
        Text.printColor("SHA256: \(sha256Hash)", .cyan)
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
        Text.printColor("Installing \(appName) to /Applications...", .green)

        let fileManager = FileManager.default
        let destinationPath = "/Applications/\(appName).app"

        // Remove existing app if it exists
        if fileManager.fileExists(atPath: destinationPath) {
            Text.printColor("Removing existing \(appName) from /Applications...", .yellow)
            try fileManager.removeItem(atPath: destinationPath)
        }

        // Copy the app to /Applications
        try fileManager.copyItem(atPath: appPath, toPath: destinationPath)

        // Set proper permissions
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try fileManager.setAttributes(attributes, ofItemAtPath: destinationPath)

        Text.printColor("✅ \(appName) installed successfully to /Applications!", .green)
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
            "-volname", volumeName,
            "-srcfolder", appPath,
            "-ov",
            "-format", "UDZO",
            outputPath,
        ]

        try hdiutilProcess.run()
        hdiutilProcess.waitUntilExit()

        guard hdiutilProcess.terminationStatus == 0 else {
            Self.logger.logAndExit(BuildError.buildFailed("DMG creation failed with exit code \(hdiutilProcess.terminationStatus)"))
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
            "-c", "-k", "--sequesterRsrc",
            appPath,
            outputPath,
        ]

        try dittoProcess.run()
        dittoProcess.waitUntilExit()

        guard dittoProcess.terminationStatus == 0 else {
            Self.logger.logAndExit(BuildError.buildFailed("Zip creation failed with exit code \(dittoProcess.terminationStatus)"))
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
        Text.printColor("Building Xcode \(containerKind == .workspace ? "workspace" : "project"): \(scheme) [\(configuration)]", .green)

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
            Self.logger.logAndExit(BuildError.buildFailed("Xcode build failed with exit code \(buildProcess.terminationStatus)"))
        }

        Text.printColor("Build completed successfully!", .green)
    }

    /// Builds a Swift package.
    ///
    /// - Parameters:
    ///   - packagePath: The path to the Swift package.
    ///   - packageName: The name of the Swift package.
    ///   - configuration: Debug or Release.
    func buildSwiftPackage(packagePath: String, packageName: String, configuration: String) throws {
        Text.printColor("Building Swift package: \(packageName) [\(configuration)]", .green)

        let swiftpmConfig = configuration.lowercased()
        guard swiftpmConfig == "debug" || swiftpmConfig == "release" else {
            Self.logger.logAndExit(BuildError.buildFailed("Invalid SwiftPM configuration '\(configuration)'. Use Debug or Release."))
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
            Self.logger.logAndExit(BuildError.buildFailed("Swift build failed with exit code \(buildProcess.terminationStatus)"))
        }

        Text.printColor("Build completed successfully!", .green)
    }

    /// Archives an Xcode project/workspace for release.
    ///
    /// - Parameters:
    ///   - containerKind: Whether this is a project or workspace.
    ///   - containerPath: The .xcodeproj or .xcworkspace path.
    ///   - scheme: The scheme to archive.
    ///   - version: The version to archive the project with.
    func archiveXcodeProject(containerKind: XcodeContainerKind, containerPath: String, scheme: String, version: String) throws {
        Text.printColor("Archiving \(scheme) with version \(version)...", .green)

        // First, set the version in the project
        try setProjectVersion(projectPath: containerPath, version: version)

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
            Self.logger.logAndExit(BuildError.buildFailed("Archive failed with exit code \(archiveProcess.terminationStatus)"))
        }

        Text.printColor("Archive complete! Now you can use Xcode Organizer for distribution.", .green)
    }

    /// Sets the version of a project.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the project/workspace (we use its parent dir to run agvtool).
    ///   - version: The version to set.
    func setProjectVersion(projectPath: String, version: String) throws {
        Text.printColor("Setting version to: \(version)", .green)

        let projectDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path

        // For prerelease versions, we need to handle them differently
        // agvtool expects standard semantic versions, so we'll use a workaround
        let (marketingVersion, buildNumber) = parseVersionForAgvtool(version)

        // Set marketing version
        let setVersionProcess = Process()
        setVersionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        setVersionProcess.arguments = ["agvtool", "new-marketing-version", marketingVersion]
        setVersionProcess.currentDirectoryPath = projectDir

        try setVersionProcess.run()
        setVersionProcess.waitUntilExit()

        guard setVersionProcess.terminationStatus == 0 else {
            Self.logger.logAndExit(BuildError.buildFailed("Failed to set marketing version '\(marketingVersion)' with exit code \(setVersionProcess.terminationStatus)"))
        }

        // Set build number
        let setBuildProcess = Process()
        setBuildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        setBuildProcess.arguments = ["agvtool", "new-version", "-all", buildNumber]
        setBuildProcess.currentDirectoryPath = projectDir

        try setBuildProcess.run()
        setBuildProcess.waitUntilExit()

        guard setBuildProcess.terminationStatus == 0 else {
            Self.logger.logAndExit(BuildError.buildFailed("Failed to set build number '\(buildNumber)' with exit code \(setBuildProcess.terminationStatus)"))
        }
    }

    /// Parses a version string to extract components suitable for agvtool.
    ///
    /// - Parameter version: The version string to parse.
    /// - Returns: A tuple of (marketingVersion, buildNumber) where marketingVersion is agvtool-compatible.
    func parseVersionForAgvtool(_ version: String) -> (marketingVersion: String, buildNumber: String) {
        // If it's already a standard semantic version (no prerelease identifiers), use as-is
        if !version.contains("-"), !version.contains("+") {
            return (version, version)
        }

        // Handle prerelease versions according to semantic versioning standards
        if let prereleaseVersion = parsePrereleaseVersion(version) {
            return prereleaseVersion
        }

        // For versions with build metadata like "1.0.0+123", extract the version part
        let buildComponents = version.split(separator: "+", maxSplits: 1)
        if buildComponents.count == 2 {
            let versionPart = String(buildComponents[0])
            return (versionPart, version)
        }

        // Fallback: use the version as-is for both
        return (version, version)
    }

    /// Parses a prerelease version string according to semantic versioning standards.
    ///
    /// - Parameter version: The version string to parse.
    /// - Returns: A tuple of (marketingVersion, buildNumber) if parsing succeeds, nil otherwise.
    func parsePrereleaseVersion(_ version: String) -> (marketingVersion: String, buildNumber: String)? {
        // Handle formats like "2.0-beta6", "2.0.0-beta.6", "1.0.0-alpha.1"
        let prereleasePattern = #"^(\d+(?:\.\d+)*)(?:\.0+)?-([a-zA-Z0-9.-]+)$"#
        let regex = try? NSRegularExpression(pattern: prereleasePattern)
        let range = NSRange(version.startIndex..., in: version)

        guard let match = regex?.firstMatch(in: version, range: range),
              let baseVersionRange = Range(match.range(at: 1), in: version)
        else {
            return nil
        }

        let baseVersion = String(version[baseVersionRange])

        // Ensure the base version has at least major.minor.patch (e.g., "2.0" -> "2.0.0")
        let normalizedBaseVersion = normalizeVersionString(baseVersion)

        return (normalizedBaseVersion, version)
    }

    /// Normalizes a version string to ensure it's compatible with agvtool.
    ///
    /// - Parameter version: The version string to normalize.
    /// - Returns: A version string that agvtool can accept.
    func normalizeVersionString(_ version: String) -> String {
        let components = version.split(separator: ".").map(String.init)

        switch components.count {
        case 1:
            // "2" -> "2.0" (agvtool prefers at least major.minor)
            return "\(components[0]).0"
        case 2:
            // "2.0" -> "2.0" (already good)
            return version
        default:
            // "2.0.0" or longer -> use as-is
            return version
        }
    }

    /// Kills an existing process.
    ///
    /// - Parameter processName: The name of the process to kill.
    func killExistingProcess(named processName: String) {
        Text.printColor("Killing existing process: \(processName)", .green)

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
                Self.logger.logAndExit(BuildError.buildFailed("Could not find built app/executable for \(projectName)"))
            }

            Text.printColor("Running: \(appPath)", .green)

            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: appPath)
            runProcess.arguments = runArguments
            runProcess.standardOutput = FileHandle.standardOutput
            runProcess.standardError = FileHandle.standardError
            runProcess.standardInput = FileHandle.standardInput

            try runProcess.run()

        case let .swiftPackage(path, _):
            // Swift packages can have multiple executables, so identify or ask
            let executables = try findSwiftPackageExecutables(at: path)

            switch executables.count {
            case 0:
                Self.logger.logAndExit(BuildError.buildFailed("No executable targets found in Swift package."))
            case 1:
                let target = targetName ?? executables[0]
                if let specifiedTarget = targetName, !executables.contains(specifiedTarget) {
                    Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                }
                Text.printColor("Running Swift package executable: \(target)", .green)
                try runSwiftPackageTarget(at: path, target: target, configuration: configuration, runArguments: runArguments)
            default:
                if let specifiedTarget = targetName {
                    if executables.contains(specifiedTarget) {
                        Text.printColor("Running Swift package executable: \(specifiedTarget)", .green)
                        try runSwiftPackageTarget(at: path, target: specifiedTarget, configuration: configuration, runArguments: runArguments)
                    } else {
                        Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                    }
                } else {
                    let executableList = executables.joined(separator: ", ")
                    Self.logger.logAndExit(BuildError.multipleExecutables(
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
            Self.logger.logAndExit(BuildError.buildFailed("Failed to dump package manifest (exit code \(dump.terminationStatus))"))
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
            Self.logger.logAndExit(BuildError.buildFailed("Could not parse dump-package JSON: \(error)"))
        }

        // Prefer executable products
        var names: [String] = []
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
            Self.logger.logAndExit(BuildError.buildFailed("Invalid SwiftPM configuration '\(configuration)'. Use Debug or Release."))
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
