//
//  SwBuilder.swift
//  dsbin-swift
//
//  Created by Danny Stewart on 9/25/25.
//

import ArgumentParser
import Foundation
import PolyLog

@main
struct SwiftBuilder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swbuilder",
        abstract: "Build Xcode projects or Swift packages with optional version bumping."
    )

    private static let logger = PolyLog(simple: true)

    @Argument(help: "Path to directory with Xcode project or Package.swift")
    var projectPath: String?

    @Flag(name: .long, help: "Increment the version number.")
    var bumpVersion = false

    @Flag(name: .long, help: "Build release version.")
    var release = false

    @Flag(name: .customLong("run"), help: "Run the app after building.")
    var shouldRun = false

    func run() throws {
        // Get project path from command line or current directory
        let inputPath = projectPath ?? FileManager.default.currentDirectoryPath

        // Check if it's an Xcode project or Swift package
        if let project = findXcodeProject(in: inputPath) {
            try buildXcodeProject(project: project)
        } else if isSwiftPackage(in: inputPath) {
            try buildSwiftPackage(in: inputPath)
        } else {
            Self.logger.error("Couldn't find Xcode or Swift package at \(inputPath)")
            return
        }

        // Run the app if requested
        if shouldRun {
            let projectName = extractPackageName(from: inputPath) ?? "Unknown"
            let appPath = findBuiltApp(projectName: projectName)
            if let app = appPath {
                let runProcess = Process()
                runProcess.executableURL = URL(fileURLWithPath: app)
                try? runProcess.run()
            }
        }
    }

    func buildXcodeProject(project: String) throws {
        let releaseType = release ? "release" : "debug"
        Self.logger.info("Building \(releaseType) version of Xcode project at \(project)...")

        // Extract project name from path
        let projectName = URL(fileURLWithPath: project).deletingPathExtension().lastPathComponent

        // Kill existing process
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", projectName]
        try? killProcess.run()

        // Increment build number if requested
        if bumpVersion {
            let versionProcess = Process()
            versionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            versionProcess.arguments = ["agvtool", "next-version", "-all"]
            versionProcess.currentDirectoryPath =
                URL(fileURLWithPath: project).deletingLastPathComponent().path
            try? versionProcess.run()
            versionProcess.waitUntilExit()
        }

        // Build the project with appropriate configuration
        let configuration = release ? "Release" : "Debug"
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        buildProcess.arguments = [
            "xcodebuild", "-project", project, "-scheme", projectName, "-configuration",
            configuration,
            "build",
        ]
        do {
            try buildProcess.run()
        } catch {
            Self.logger.error("Build failed: \(error)")
            throw error
        }
        buildProcess.waitUntilExit()

        // Find and run the built app
        let appPath = findBuiltApp(projectName: projectName)
        if let app = appPath {
            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: app)
            try? runProcess.run()
        }
    }

    func buildSwiftPackage(in path: String) throws {
        let releaseType = release ? "release" : "debug"
        Self.logger.info("Building \(releaseType) version of Swift package at \(path)...")

        // Extract package name from Package.swift
        let packageName = extractPackageName(from: path) ?? "Unknown"

        // Kill existing process
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", packageName]
        try? killProcess.run()

        // Build the Swift package with appropriate configuration
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        let buildArgs = release ? ["build", "-c", "release"] : ["build"]
        buildProcess.arguments = buildArgs
        buildProcess.currentDirectoryPath = path
        try? buildProcess.run()
        buildProcess.waitUntilExit()

        // Find and run the built app
        let appPath = findBuiltApp(projectName: packageName)
        if let app = appPath {
            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: app)
            try? runProcess.run()
        }
    }

    func isSwiftPackage(in path: String) -> Bool {
        let packageSwiftPath = "\(path)/Package.swift"
        return FileManager.default.fileExists(atPath: packageSwiftPath)
    }

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

    func findXcodeProject(in path: String = FileManager.default.currentDirectoryPath)
        -> String?
    {
        // Look for .xcodeproj files in the given path
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for item in contents {
                if item.hasSuffix(".xcodeproj") {
                    return "\(path)/\(item)"
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    func findBuiltApp(projectName: String) -> String? {
        // Look in DerivedData for the built app
        let derivedDataPath = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: derivedDataPath)
            for item in contents {
                if item.hasPrefix(projectName) {
                    let appPaths = [
                        "\(derivedDataPath)/\(item)/Build/Products/Debug/\(projectName).app/Contents/MacOS/\(projectName)",
                        "\(derivedDataPath)/\(item)/Build/Products/Release/\(projectName).app/Contents/MacOS/\(projectName)",
                    ]
                    for buildPath in appPaths {
                        if fileManager.fileExists(atPath: buildPath) {
                            return buildPath
                        }
                    }
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

        for buildPath in localBuildPaths {
            if fileManager.fileExists(atPath: buildPath) {
                return buildPath
            }
        }

        return nil
    }
}
