import Crypto
import Foundation
import PolyKit

enum ReleasePackager {
    static func prepareFromDownloads(
        projectName: String,
        version: String,
        shouldInstallToApplications: Bool,
    ) throws {
        SwiftDeploy.printInfo("Preparing release packages for \(projectName) \(version)...")

        let home = NSHomeDirectory()
        let appPath = "\(home)/Downloads/\(projectName).app"
        let outputPath = "\(home)/Developer/\(projectName)/releases"

        let fm = FileManager.default
        guard fm.fileExists(atPath: appPath) else {
            throw DevError.buildFailed("App not found at \(appPath). Please export the .app to ~/Downloads first.")
        }

        try fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        let dmgPath = "\(outputPath)/\(projectName)-\(version).dmg"
        SwiftDeploy.printInfo("Creating DMG at \(dmgPath)")
        try self.createDMG(appPath: appPath, outputPath: dmgPath, volumeName: projectName)

        SwiftDeploy.printInfo("Calculating SHA256...")
        let sha256 = try sha256Hex(of: dmgPath)
        SwiftDeploy.printInfo("SHA256: \(sha256)")

        let zipPath = "\(outputPath)/\(projectName)-\(version).zip"
        SwiftDeploy.printInfo("Creating zip at \(zipPath)")
        try self.createZip(appPath: appPath, outputPath: zipPath)

        if shouldInstallToApplications {
            try self.installAppToApplications(appPath: appPath, appName: projectName)
            try self.cleanupOriginalApp(at: appPath)
        }

        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [outputPath]
        try openProcess.run()

        SwiftDeploy.printInfo("Release packages created at \(outputPath)")
    }

    // MARK: Packaging

    static func createDMG(appPath: String, outputPath: String, volumeName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
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
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DevError.buildFailed("DMG creation failed with exit code \(process.terminationStatus)")
        }
    }

    static func createZip(appPath: String, outputPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", appPath, outputPath]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DevError.buildFailed("Zip creation failed with exit code \(process.terminationStatus)")
        }
    }

    // MARK: Hashing

    static func sha256Hex(of filePath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Installation

    static func installAppToApplications(appPath: String, appName: String) throws {
        SwiftDeploy.printInfo("Installing \(appName) to /Applications...")

        let fm = FileManager.default
        let destinationPath = "/Applications/\(appName).app"

        if fm.fileExists(atPath: destinationPath) {
            SwiftDeploy.printWarning("Removing existing \(appName) from /Applications...")
            try fm.removeItem(atPath: destinationPath)
        }

        try fm.copyItem(atPath: appPath, toPath: destinationPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)

        SwiftDeploy.printInfo("Installed to \(destinationPath)")
    }

    static func cleanupOriginalApp(at appPath: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appPath) else { return }
        SwiftDeploy.printInfo("Cleaning up original app from Downloads...")
        try fm.removeItem(atPath: appPath)
    }
}
