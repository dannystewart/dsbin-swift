import ArgumentParser
import Foundation
import PolyLog

@main
struct SwiftBuilder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swbuilder",
        abstract: "Build Xcode projects or Swift packages with optional running or archiving."
    )

    private static let logger = PolyLog(simple: true)

    @Argument(help: "Path to directory with Xcode project or Package.swift.")
    var projectPath: String?

    @Flag(name: .customLong("run"), help: "Run the app after building.")
    var shouldRun = false

    @Flag(name: .long, help: "Kill existing process, build, then run.")
    var restart = false

    @Option(name: .long, help: "Archive for release with specified version (e.g., 1.2.3).")
    var release: String?

    @Option(name: .long, help: "Prepare release with DMG and ZIP packages for specified version (e.g., 1.2.3).")
    var prepare: String?

    /// The type of project, either an Xcode project or a Swift package.
    enum ProjectType {
        case xcodeProject(path: String, name: String)
        case swiftPackage(path: String, name: String)
    }

    /// The error type given when building projects.
    enum BuildError: Error, LocalizedError {
        case invalidProject(String)
        case buildFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidProject(message): return message
            case let .buildFailed(message): return message
            }
        }

        func logAndThrow(warning: Bool = false) -> Never {
            if warning { SwiftBuilder.logger.warning(localizedDescription) } else { SwiftBuilder.logger.error(localizedDescription) }
            Foundation.exit(1)
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
                BuildError
                    .invalidProject("Found Package.swift but couldn't extract package name")
                    .logAndThrow()
            }
            return .swiftPackage(path: path, name: packageName)
        }

        BuildError
            .invalidProject("No Xcode project or Package.swift found at \(path)")
            .logAndThrow()
    }

    /// Validates the command line arguments.
    ///
    /// - Throws: An error if the version format is invalid or both run and restart are specified.
    func validate() throws {
        // Validate version format if provided
        if let version = release {
            let versionRegex = try NSRegularExpression(pattern: #"^\d+\.\d+(\.\d+)?$"#)
            let range = NSRange(version.startIndex..., in: version)
            guard versionRegex.firstMatch(in: version, range: range) != nil else {
                throw ValidationError("Version must be in format x.y or x.y.z (e.g., 1.2.3)")
            }
        }

        // Validate prepare version format if provided
        if let version = prepare {
            let versionRegex = try NSRegularExpression(pattern: #"^\d+\.\d+(\.\d+)?$"#)
            let range = NSRange(version.startIndex..., in: version)
            guard versionRegex.firstMatch(in: version, range: range) != nil else {
                throw ValidationError("Version must be in format x.y or x.y.z (e.g., 1.2.3)")
            }
        }

        // Can't use both run and restart
        if shouldRun, restart {
            throw ValidationError("Cannot specify both --run and --restart")
        }
    }

    /// Executes the main build workflow based on command line arguments.
    func run() throws {
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath

        // Determine project type (should never fail for valid projects)
        let projectType = try determineProjectType(at: inputPath)

        // Handle the operation based on flags
        if let version = release {
            try archiveForRelease(projectType: projectType, version: version)
        } else if let version = prepare {
            try prepareReleaseForUpload(projectType: projectType, version: version)
        } else {
            try buildForDevelopment(projectType: projectType)
        }
    }

    /// Builds a project for development.
    ///
    /// - Parameter projectType: The type of project to build.
    /// - Throws: An error if the project cannot be built.
    func buildForDevelopment(projectType: ProjectType) throws {
        // Handle killing existing process if restart is requested
        if restart {
            let projectName = switch projectType {
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
            let projectName = switch projectType {
            case let .xcodeProject(_, name): name
            case let .swiftPackage(_, name): name
            }
            try runBuiltApp(projectName: projectName, projectType: projectType)
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
            BuildError
                .buildFailed(
                    "Archiving is not supported for Swift packages. Use 'swift build -c release' instead."
                )
                .logAndThrow()
        }
    }

    /// Prepares release packages (DMG and ZIP) from an archived app.
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
            BuildError
                .buildFailed(
                    "Release preparation is not supported for Swift packages. Only Xcode projects can be packaged."
                )
                .logAndThrow()
        }
    }

    /// Prepares DMG and ZIP packages for an Xcode project.
    ///
    /// - Parameters:
    ///   - projectName: The name of the project.
    ///   - version: The version for the packages.
    /// - Throws: An error if the packages cannot be created.
    func prepareXcodeProjectRelease(projectName: String, version: String) throws {
        Self.logger.info("Preparing release packages for \(projectName) version \(version)")

        // Define paths
        let homeDirectory = NSHomeDirectory()
        let appPath = "\(homeDirectory)/Downloads/\(projectName).app"
        let outputPath = "\(homeDirectory)/Developer/\(projectName)/release"

        // Check if the app exists in Downloads
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appPath) else {
            BuildError
                .buildFailed(
                    "App not found at \(appPath). Please ensure the app is exported to Downloads first."
                )
                .logAndThrow()
        }

        // Create output directory if needed
        try fileManager.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        // Create DMG
        Self.logger.info("Creating DMG package...")
        try createDMG(
            appPath: appPath,
            outputPath: "\(outputPath)/\(projectName)-\(version).dmg",
            volumeName: projectName
        )

        // Create ZIP
        Self.logger.info("Creating ZIP package...")
        try createZIP(
            appPath: appPath,
            outputPath: "\(outputPath)/\(projectName)-\(version).zip"
        )

        // Open the releases folder
        Self.logger.info("Opening release folder...")
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [outputPath]
        try openProcess.run()

        Self.logger.info("Release packages created successfully at \(outputPath)")
    }

    /// Creates a DMG package from an app.
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
            BuildError
                .buildFailed("DMG creation failed with exit code \(hdiutilProcess.terminationStatus)")
                .logAndThrow()
        }
    }

    /// Creates a ZIP package from an app.
    ///
    /// - Parameters:
    ///   - appPath: The path to the .app bundle.
    ///   - outputPath: The path where the ZIP should be created.
    /// - Throws: An error if the ZIP cannot be created.
    func createZIP(appPath: String, outputPath: String) throws {
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
            BuildError
                .buildFailed("ZIP creation failed with exit code \(dittoProcess.terminationStatus)")
                .logAndThrow()
        }
    }

    /// Builds an Xcode project.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the Xcode project.
    ///   - projectName: The name of the Xcode project.
    /// - Throws: An error if the Xcode project cannot be built.
    func buildXcodeProject(projectPath: String, projectName: String) throws {
        Self.logger.info("Building Xcode project: \(projectName)")

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
            BuildError
                .buildFailed("Xcode build failed with exit code \(buildProcess.terminationStatus)")
                .logAndThrow()
        }

        Self.logger.info("Build completed successfully")
    }

    /// Builds a Swift package.
    ///
    /// - Parameters:
    ///   - packagePath: The path to the Swift package.
    ///   - packageName: The name of the Swift package.
    /// - Throws: An error if the Swift package cannot be built.
    func buildSwiftPackage(packagePath: String, packageName: String) throws {
        Self.logger.info("Building Swift package: \(packageName)")

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
            BuildError
                .buildFailed("Swift build failed with exit code \(buildProcess.terminationStatus)")
                .logAndThrow()
        }

        Self.logger.info("Build completed successfully")
    }

    /// Archives a Xcode project for release.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the Xcode project.
    ///   - projectName: The name of the Xcode project.
    ///   - version: The version to archive the project with.
    /// - Throws: An error if the Xcode project cannot be archived.
    func archiveXcodeProject(projectPath: String, projectName: String, version: String) throws {
        Self.logger.info("Archiving \(projectName) with version \(version)")

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
            BuildError
                .buildFailed("Archive failed with exit code \(archiveProcess.terminationStatus)")
                .logAndThrow()
        }

        Self.logger.info("Archive completed successfully - check Xcode Organizer for next steps")
    }

    /// Sets the version of a project.
    ///
    /// - Parameters:
    ///   - projectPath: The path to the project.
    ///   - version: The version to set.
    /// - Throws: An error if the version cannot be set.
    func setProjectVersion(projectPath: String, version: String) throws {
        Self.logger.info("Setting version to \(version)")

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
        Self.logger.info("Killing existing process: \(processName)")

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
    /// - Throws: An error if the app cannot be run.
    func runBuiltApp(projectName: String, projectType: ProjectType) throws {
        switch projectType {
        case .xcodeProject:
            // Xcode projects typically have one main executable
            guard let appPath = findBuiltApp(projectName: projectName) else {
                BuildError.buildFailed("Could not find built app for \(projectName)").logAndThrow()
            }

            Self.logger.info("Running app: \(appPath)")

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
                BuildError.buildFailed("No executable targets found in Swift package").logAndThrow()
            case 1:
                let target = executables[0]
                Self.logger.info("Running Swift package executable: \(target)")
                try runSwiftPackageTarget(at: path, target: target)
            default:
                let executableList = executables.joined(separator: ", ")
                BuildError.buildFailed(
                    "Multiple executables found:\n \(executableList) " +
                        "\n\nPlease specify which to run: swbuilder --run <executable-name>"
                ).logAndThrow(warning: true)
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

    /// Finds all executable targets defined in a Swift package.
    ///
    /// - Parameter path: The path to the Swift package directory.
    /// - Returns: An array of executable target names.
    /// - Throws: BuildError if Package.swift cannot be read or parsed.
    func findSwiftPackageExecutables(at path: String) throws -> [String] {
        // Parse Package.swift to find executable targets
        let packageSwiftPath = "\(path)/Package.swift"

        do {
            let content = try String(contentsOfFile: packageSwiftPath, encoding: .utf8)

            // Look for executable targets - this regex finds .executableTarget patterns
            let executablePattern = #"\.executableTarget\s*\(\s*name:\s*"([^"]+)""#
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
            BuildError.buildFailed("Could not read Package.swift: \(error)").logAndThrow()
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
