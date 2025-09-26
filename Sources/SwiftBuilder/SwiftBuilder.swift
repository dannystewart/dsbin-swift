//
//  SwBuilder.swift
//  DSSwift
//
//  Created by Danny Stewart on 9/25/25.
//

import Foundation
import PolyLog

let logger = PolyLog()

struct SwiftBuilder {
    static func main() {
        // Get project path from command line or current directory
        let inputPath =
            CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath

        guard let project = findXcodeProject(in: inputPath) else {
            logger.error("No Xcode project found.")
            return
        }

        logger.info("Building project at: \(project)")

        // Extract project name from path
        let projectName = URL(fileURLWithPath: project).deletingPathExtension().lastPathComponent

        // Kill existing process
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", projectName]
        try? killProcess.run()

        // Increment build number
        let versionProcess = Process()
        versionProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        versionProcess.arguments = ["agvtool", "next-version", "-all"]
        versionProcess.currentDirectoryPath =
            URL(fileURLWithPath: project).deletingLastPathComponent().path
        try? versionProcess.run()
        versionProcess.waitUntilExit()

        // Build the project
        let buildProcess = Process()
        buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        buildProcess.arguments = [
            "xcodebuild", "-project", project, "-scheme", projectName, "-configuration", "Debug",
            "build",
        ]
        try? buildProcess.run()
        buildProcess.waitUntilExit()

        // Find and run the built app
        let appPath = findBuiltApp(projectName: projectName)
        if let app = appPath {
            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: app)
            try? runProcess.run()
        }
    }

    static func findXcodeProject(in path: String = FileManager.default.currentDirectoryPath)
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

    static func findBuiltApp(projectName: String) -> String? {
        // Look in DerivedData for the built app
        let derivedDataPath = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: derivedDataPath)
            for item in contents {
                if item.hasPrefix(projectName) {
                    let appPath =
                        "\(derivedDataPath)/\(item)/Build/Products/Debug/\(projectName).app/Contents/MacOS/\(projectName)"
                    if fileManager.fileExists(atPath: appPath) {
                        return appPath
                    }
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}

SwiftBuilder.main()
