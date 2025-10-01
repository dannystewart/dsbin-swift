import ArgumentParser
import Foundation
import Polykit

// MARK: - SwiftBuilder

@main
struct SwiftBuilder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swbuilder",
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

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.buildForDevelopment(projectType: projectType)
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

    @Flag(name: .long, help: "Kill existing process, build, then run.")
    var restart = false

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.buildForDevelopment(
            projectType: projectType,
            shouldRun: true,
            targetName: target,
            restart: restart,
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

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Argument(help: "Version for the release packages (e.g., 1.2.3).")
    var version: String

    func run() throws {
        let builder = SwiftBuilder()
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath
        let projectType = try builder.determineProjectType(at: inputPath)
        try builder.prepareReleaseForUpload(projectType: projectType, version: version)
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

// MARK: - SwiftBuilder

extension SwiftBuilder {
    /// The type of project, either an Xcode project or a Swift package.
    enum ProjectType {
        case xcodeProject(path: String, name: String)
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
        let fileManager = FileManager.default

        // Check for Xcode project first
        if let xcodeProject = findXcodeProject(in: path) {
            let projectName = URL(fileURLWithPath: xcodeProject)
                .deletingPathExtension()
                .lastPathComponent
            return .xcodeProject(path: xcodeProject, name: projectName)
        }

        // Check for Swift package
        let packageSwiftPath = "\(path)/Package.swift"
        if fileManager.fileExists(atPath: packageSwiftPath) {
            guard let packageName = extractPackageName(from: path) else {
                Self.logger.logAndExit(BuildError.invalidProject("Found Package.swift but couldn't extract package name"))
            }
            return .swiftPackage(path: path, name: packageName)
        }

        Self.logger.logAndExit(BuildError.invalidProject("No Xcode project or Package.swift found at \(path)"))
    }

    /// Builds a project for development.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to build.
    ///   - shouldRun: Whether to run the app after building.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    ///   - restart: Whether to kill existing process before running.
    /// - Throws: An error if the project cannot be built.
    func buildForDevelopment(
        projectType: ProjectType,
        shouldRun: Bool = false,
        targetName: String? = nil,
        restart: Bool = false,
    ) throws {
        // Handle killing existing process if restart is requested
        if restart {
            let projectName =
                switch projectType {
                case let .xcodeProject(_, name): name
                case let .swiftPackage(_, name): name
                }
            killExistingProcess(named: projectName)
        }

        // Build the project
        switch projectType {
        case let .xcodeProject(path, name):
            try buildXcodeProject(projectPath: path, projectName: name)
        case let .swiftPackage(path, name):
            try buildSwiftPackage(packagePath: path, packageName: name)
        }

        // Run if requested
        if shouldRun || restart {
            let projectName =
                switch projectType {
                case let .xcodeProject(_, name): name
                case let .swiftPackage(_, name): name
                }
            try runBuiltApp(projectName: projectName, projectType: projectType, targetName: targetName)
        }
    }

    /// Archives a project for release. This prepares a project to be validated and distributed. Note that
    /// actual validation and distribution must still be done within the Xcode Organizer.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to archive.
    ///   - version: The version to archive the project with.
    /// - Throws: An error if the project cannot be archived.
    func archiveForRelease(projectType: ProjectType, version: String) throws {
        switch projectType {
        case let .xcodeProject(path, name):
            try archiveXcodeProject(projectPath: path, projectName: name, version: version)
        case .swiftPackage:
            Self.logger.logAndExit(BuildError.buildFailed("Archiving is not supported for Swift packages. Use 'swift build -c release' instead."))
        }
    }

    /// Prepares release packages (DMG and zip) from an archived app.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to prepare.
    ///   - version: The version for the release packages.
    /// - Throws: An error if the packages cannot be created.
    func prepareReleaseForUpload(projectType: ProjectType, version: String) throws {
        switch projectType {
        case let .xcodeProject(_, name):
            try prepareXcodeProjectRelease(projectName: name, version: version)
        case .swiftPackage:
            Self.logger.logAndExit(BuildError.buildFailed("Release preparation is not supported for Swift packages. Only Xcode projects can be packaged."))
        }
    }

    /// Installs the built executable by creating a symlink in ~/.local/bin.
    ///
    /// - Parameters:
    ///   - projectType: The type of project to install.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    /// - Throws: An error if the executable cannot be installed.
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
    /// - Throws: An error if the executable cannot be found.
    func getExecutableInfo(projectType: ProjectType, targetName: String?) throws -> (path: String, name: String) {
        switch projectType {
        case let .xcodeProject(_, name):
            guard let appPath = findBuiltApp(projectName: name) else {
                Self.logger.logAndExit(BuildError.buildFailed("Could not find built app for \(name)"))
            }
            return (appPath, name)

        case let .swiftPackage(path, _):
            let executables = try findSwiftPackageExecutables(at: path)

            switch executables.count {
            case 0:
                Self.logger.logAndExit(BuildError.buildFailed("No executable targets found in Swift package"))
            case 1:
                let target = targetName ?? executables[0]
                if let specifiedTarget = targetName, !executables.contains(specifiedTarget) {
                    Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                }
                let executablePath = "\(path)/.build/debug/\(target)"
                return (executablePath, target)
            default:
                if let specifiedTarget = targetName {
                    if executables.contains(specifiedTarget) {
                        let executablePath = "\(path)/.build/debug/\(specifiedTarget)"
                        return (executablePath, specifiedTarget)
                    } else {
                        Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                    }
                } else {
                    let executableList = executables.joined(separator: ", ")
                    Self.logger.logAndExit(BuildError.multipleExecutables("Multiple executables found:\n \(executableList)\n\nPlease specify which to install: swbuilder install --target <executable-name>"))
                }
            }
        }
    }

    /// Prepares DMG and zip packages for an Xcode project. NOTE: This is hardcoded to look for the .app bundle in
    /// `~/Downloads` and to export the release to the `releases` folder alongside the project.
    ///
    /// - Parameters:
    ///   - projectName: The name of the project.
    ///   - version: The version for the packages.
    /// - Throws: An error if the packages cannot be created.
    func prepareXcodeProjectRelease(projectName: String, version: String) throws {
        Text.printColor("Preparing release packages for \(projectName) \(version)...", .green)

        // Define paths
        let homeDirectory = NSHomeDirectory()
        let appPath = "\(homeDirectory)/Downloads/\(projectName).app"
        let outputPath = "\(homeDirectory)/Developer/\(projectName)/release"

        // Check if the app exists in Downloads
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appPath) else {
            Self.logger.logAndExit(BuildError.buildFailed("App not found at \(appPath). Please ensure the app is exported to Downloads first."))
        }

        // Create output directory if needed
        try fileManager.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        // Create DMG
        Text.printColor("Creating DMG file...", .green)
        try createDMG(
            appPath: appPath,
            outputPath: "\(outputPath)/\(projectName)-\(version).dmg",
            volumeName: projectName,
        )

        // Create zip
        Text.printColor("Creating zip file...", .green)
        try createZip(
            appPath: appPath,
            outputPath: "\(outputPath)/\(projectName)-\(version).zip",
        )

        // Open the releases folder
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [outputPath]
        try openProcess.run()

        Text.printColor("Release packages created successfully: \(outputPath)", .green)
    }

    /// Creates a DMG image from an app.
    ///
    /// - Parameters:
    ///   - appPath: The path to the .app bundle.
    ///   - outputPath: The path where the DMG should be created.
    ///   - volumeName: The name for the DMG volume.
    /// - Throws: An error if the DMG cannot be created.
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
    /// - Throws: An error if the zip file cannot be created.
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

    /// Builds an Xcode project.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the Xcode project.
    ///   - projectName: The name of the Xcode project.
    /// - Throws: An error if the Xcode project cannot be built.
    func buildXcodeProject(projectPath: String, projectName: String) throws {
        Text.printColor("Building Xcode project: \(projectName)", .green)

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        buildProcess.arguments = [
            "xcodebuild", "-project", projectPath, "-scheme", projectName,
            "-configuration", "Debug", "build",
        ]

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
    /// - Throws: An error if the Swift package cannot be built.
    func buildSwiftPackage(packagePath: String, packageName: String) throws {
        Text.printColor("Building Swift package: \(packageName)", .green)

        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        buildProcess.arguments = ["build"]
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

    /// Archives a Xcode project for release.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the Xcode project.
    ///   - projectName: The name of the Xcode project.
    ///   - version: The version to archive the project with.
    /// - Throws: An error if the Xcode project cannot be archived.
    func archiveXcodeProject(projectPath: String, projectName: String, version: String) throws {
        Text.printColor("Archiving \(projectName) with version \(version)...", .green)

        // First, set the version in the project
        try setProjectVersion(projectPath: projectPath, version: version)

        // Now archive
        let archiveProcess = Process()
        archiveProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        archiveProcess.arguments = [
            "xcodebuild", "-project", projectPath, "-scheme", projectName,
            "-configuration", "Release", "archive",
        ]

        // Stream output directly
        archiveProcess.standardOutput = FileHandle.standardOutput
        archiveProcess.standardError = FileHandle.standardError

        try archiveProcess.run()
        archiveProcess.waitUntilExit()

        guard archiveProcess.terminationStatus == 0 else {
            Self.logger.logAndExit(BuildError.buildFailed("Archive failed with exit code \(archiveProcess.terminationStatus)"))
        }

        Text.printColor("Archive complete! Now use Xcode Organizer to distribute.", .green)
    }

    /// Sets the version of a project.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the project.
    ///   - version: The version to set.
    /// - Throws: An error if the version cannot be set.
    func setProjectVersion(projectPath: String, version: String) throws {
        Text.printColor("Setting version to: \(version)", .green)

        let projectDir = URL(fileURLWithPath: projectPath).deletingLastPathComponent().path

        // Set both version and build number to the same value
        let setVersionProcess = Process()
        setVersionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        setVersionProcess.arguments = ["agvtool", "new-marketing-version", version]
        setVersionProcess.currentDirectoryPath = projectDir

        try setVersionProcess.run()
        setVersionProcess.waitUntilExit()

        let setBuildProcess = Process()
        setBuildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        setBuildProcess.arguments = ["agvtool", "new-version", "-all", version]
        setBuildProcess.currentDirectoryPath = projectDir

        try setBuildProcess.run()
        setBuildProcess.waitUntilExit()
    }

    /// Kills an existing process.
    ///
    /// - Parameter processName: The name of the process to kill.
    func killExistingProcess(named processName: String) {
        Text.printColor("Killing existing process: \(processName)", .green)

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", processName]

        // It doesn't matter if this fails since the process might not be running
        try? killProcess.run()
        killProcess.waitUntilExit()
    }

    /// Runs a built app.
    ///
    /// - Parameters:
    ///   - projectName: The name of the project.
    ///   - projectType: The type of project.
    ///   - targetName: Optional target name for Swift packages with multiple executables.
    /// - Throws: An error if the app cannot be run.
    func runBuiltApp(projectName: String, projectType: ProjectType, targetName: String? = nil) throws {
        switch projectType {
        case .xcodeProject:
            // Xcode projects typically have one main executable
            guard let appPath = findBuiltApp(projectName: projectName) else {
                Self.logger.logAndExit(BuildError.buildFailed("Could not find built app for \(projectName)"))
            }

            Text.printColor("Running app: \(appPath)", .green)

            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: appPath)
            runProcess.standardOutput = FileHandle.standardOutput
            runProcess.standardError = FileHandle.standardError
            runProcess.standardInput = FileHandle.standardInput

            try runProcess.run()

        case let .swiftPackage(path, _):
            // Swift packages can have multiple executables, so identify or ask
            let executables = try findSwiftPackageExecutables(at: path)

            switch executables.count {
            case 0:
                Self.logger.logAndExit(BuildError.buildFailed("No executable targets found in Swift package"))
            case 1:
                // If user specified a target, validate it exists; otherwise use the single target
                let target = targetName ?? executables[0]
                if let specifiedTarget = targetName, !executables.contains(specifiedTarget) {
                    Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                }
                Text.printColor("Running Swift package executable: \(target)", .green)
                try runSwiftPackageTarget(at: path, target: target)
            default:
                // Multiple executables - user must specify which one
                if let specifiedTarget = targetName {
                    if executables.contains(specifiedTarget) {
                        Text.printColor("Running Swift package executable: \(specifiedTarget)", .green)
                        try runSwiftPackageTarget(at: path, target: specifiedTarget)
                    } else {
                        Self.logger.logAndExit(BuildError.buildFailed("Executable '\(specifiedTarget)' not found. Available: \(executables.joined(separator: ", "))"))
                    }
                } else {
                    let executableList = executables.joined(separator: ", ")
                    Self.logger.logAndExit(BuildError.buildFailed("Multiple executables found:\n \(executableList)\n\nPlease specify which to run: swbuilder --run <executable-name>"))
                }
            }
        }
    }

    /// Checks if a path is a Swift package.
    ///
    /// - Parameter path: The path to check.
    /// - Returns: True if the path is a Swift package, false otherwise.
    func isSwiftPackage(in path: String) -> Bool {
        let packageSwiftPath = "\(path)/Package.swift"
        return FileManager.default.fileExists(atPath: packageSwiftPath)
    }

    /// Extracts the name of a Swift package from a path.
    ///
    /// - Parameter path: The path to extract the package name from.
    /// - Returns: The name of the Swift package.
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

    /// Finds all executable products defined in a Swift package.
    ///
    /// - Parameter path: The path to the Swift package directory.
    /// - Returns: An array of executable product names.
    /// - Throws: BuildError if Package.swift cannot be read or parsed.
    func findSwiftPackageExecutables(at path: String) throws -> [String] {
        // Parse Package.swift to find executable products
        let packageSwiftPath = "\(path)/Package.swift"

        do {
            let content = try String(contentsOfFile: packageSwiftPath, encoding: .utf8)

            // Look for executable products - this regex finds .executable patterns
            let executablePattern = #"\.executable\s*\(\s*name:\s*"([^"]+)""#
            let executableRegex = try NSRegularExpression(pattern: executablePattern)

            var executables: [String] = []
            let range = NSRange(content.startIndex..., in: content)
            let matches = executableRegex.matches(in: content, range: range)

            for match in matches {
                if let nameRange = Range(match.range(at: 1), in: content) {
                    executables.append(String(content[nameRange]))
                }
            }

            return executables
        } catch {
            Self.logger.logAndExit(BuildError.buildFailed("Could not read Package.swift: \(error)"))
        }
    }

    /// Runs a specific executable target in a Swift package.
    ///
    /// - Parameters:
    ///   - path: The path to the Swift package directory.
    ///   - target: The name of the executable target to run.
    /// - Throws: An error if the target cannot be executed.
    func runSwiftPackageTarget(at path: String, target: String) throws {
        let runProcess = Process()
        runProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        runProcess.arguments = ["run", target]
        runProcess.currentDirectoryPath = path

        runProcess.standardOutput = FileHandle.standardOutput
        runProcess.standardError = FileHandle.standardError
        runProcess.standardInput = FileHandle.standardInput

        try runProcess.run()
        runProcess.waitUntilExit()
    }

    /// Finds an Xcode project in a path.
    ///
    /// - Parameter path: The path to find the Xcode project in.
    /// - Returns: The path to the Xcode project.
    func findXcodeProject(in path: String = FileManager.default.currentDirectoryPath) -> String? {
        // Look for .xcodeproj files in the given path
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for item in contents where item.hasSuffix(".xcodeproj") {
                return "\(path)/\(item)"
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Finds a built app in the DerivedData directory.
    ///
    /// - Parameter projectName: The name of the project.
    /// - Returns: The path to the built app.
    func findBuiltApp(projectName: String) -> String? {
        // Look in DerivedData for the built app
        let derivedDataPath = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: derivedDataPath)
            for item in contents where item.hasPrefix(projectName) {
                let appPaths = [
                    "\(derivedDataPath)/\(item)/Build/Products/Debug/\(projectName).app/Contents/MacOS/\(projectName)",
                    "\(derivedDataPath)/\(item)/Build/Products/Release/\(projectName).app/Contents/MacOS/\(projectName)",
                ]
                for buildPath in appPaths where fileManager.fileExists(atPath: buildPath) {
                    return buildPath
                }
            }
        } catch {
            // Continue to fallback
        }
        // Look in the local build directory for SPM builds
        let currentDirectory = FileManager.default.currentDirectoryPath
        let localBuildPaths = [
            "\(currentDirectory)/.build/debug/\(projectName)",
            "\(currentDirectory)/.build/release/\(projectName)",
            "\(currentDirectory)/build/debug/\(projectName)",
            "\(currentDirectory)/build/release/\(projectName)",
        ]

        for buildPath in localBuildPaths where fileManager.fileExists(atPath: buildPath) {
            return buildPath
        }

        return nil
    }
}
