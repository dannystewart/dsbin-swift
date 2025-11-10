import ArgumentParser
import Foundation
import PolyKit

// MARK: - SwiftDeploy

@main
struct SwiftDeploy: ParsableCommand {
    static let configuration: CommandConfiguration = .init(
        commandName: "swdeploy",
        abstract: "Build and deploy iOS/macOS apps to devices",
        subcommands: [Build.self, Install.self, Deploy.self],
        defaultSubcommand: Deploy.self,
    )
}

// MARK: - Logger

let logger: PolyLog = .init()

// MARK: - Project

enum Project: String, CaseIterable, ExpressibleByArgument {
    case prism
    case whomix
    case polyplayer

    // MARK: Computed Properties

    var displayName: String {
        switch self {
        case .prism: "Prism"
        case .whomix: "Whomix"
        case .polyplayer: "PolyPlayer"
        }
    }

    var workspacePath: String {
        switch self {
        case .prism:
            "/Users/danny/Developer/PrismApp/Prism.xcodeproj/project.xcworkspace"
        case .whomix:
            "/Users/danny/Developer/Whomix/Whomix.xcodeproj/project.xcworkspace"
        case .polyplayer:
            "/Users/danny/Developer/PolyPlayer/PolyPlayer.xcodeproj/project.xcworkspace"
        }
    }

    var schemeName: String {
        displayName
    }

    // MARK: Functions

    /// Returns the expected .app path in DerivedData for iOS builds
    func appPath(for device: Device) -> String {
        let appName = displayName
        let derivedDataPath = "/Users/danny/Library/Developer/Xcode/DerivedData"

        // These paths from your commands - they have hashes that won't change
        let hash = switch self {
        case .prism: "eckcnaaqhfcxrwdrkwqwkhixwyfj"
        case .whomix: "gzvfugqvflgqrfbzkkbfijknatgt"
        case .polyplayer: "ezvpjuthvywtluebbreqoqyrfkao"
        }

        switch device {
        case .iphone, .ipad:
            return "\(derivedDataPath)/\(appName)-\(hash)/Build/Products/Debug-iphoneos/\(appName).app"
        case .macos:
            return "\(derivedDataPath)/\(appName)-\(hash)/Build/Products/Debug/\(appName).app"
        }
    }
}

// MARK: - Device

enum Device: String, CaseIterable, ExpressibleByArgument {
    case iphone
    case ipad
    case macos

    // MARK: Computed Properties

    var displayName: String {
        switch self {
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .macos: "macOS"
        }
    }

    var deviceID: String? {
        switch self {
        case .iphone: "00008150-001C31440108401C"
        case .ipad: "00008103-0001694C3EBB001E"
        case .macos: nil
        }
    }

    var xcodebuildDestination: String {
        switch self {
        case .iphone:
            "platform=iOS,id=00008150-001C31440108401C"
        case .ipad:
            "platform=iOS,id=00008103-0001694C3EBB001E"
        case .macos:
            "platform=macOS,arch=arm64"
        }
    }

    var canInstall: Bool {
        // Only physical iOS devices support xcrun devicectl install
        self != .macos
    }
}

// MARK: - SwiftDeploy.Build

extension SwiftDeploy {
    struct Build: ParsableCommand {
        // MARK: Static Properties

        static let configuration: CommandConfiguration = .init(
            abstract: "Build an app for a specific device/platform",
        )

        // MARK: Properties

        @Argument(help: "The project to build (prism, whomix, polyplayer)")
        var project: Project

        @Argument(help: "The target device (iphone, ipad, macos)")
        var device: Device

        @Flag(name: .shortAndLong, help: "Show verbose build output")
        var verbose = false

        // MARK: Functions

        func run() throws {
            logger.info("🔨 Building \(project.displayName) for \(device.displayName)...")

            let buildResult = buildProject(project: project, device: device, verbose: verbose)

            if buildResult.success {
                logger.info("Build completed successfully!")
                if let appPath = buildResult.appPath {
                    logger.info("App location: \(appPath)")
                }
            } else {
                logger.error("Build failed!")
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - SwiftDeploy.Install

extension SwiftDeploy {
    struct Install: ParsableCommand {
        // MARK: Static Properties

        static let configuration: CommandConfiguration = .init(
            abstract: "Install a previously-built app to a device",
        )

        // MARK: Properties

        @Argument(help: "The project to install (prism, whomix, polyplayer)")
        var project: Project

        @Argument(help: "The target device (iphone, ipad)")
        var device: Device

        // MARK: Functions

        func run() throws {
            guard device.canInstall else {
                logger.error("Cannot install to \(device.displayName) - installation only supported for iOS devices")
                throw ExitCode.failure
            }

            logger.info("📲 Installing \(project.displayName) to \(device.displayName)...")

            let appPath = project.appPath(for: device)

            // Check if the app exists
            guard FileManager.default.fileExists(atPath: appPath) else {
                logger.error("App not found at: \(appPath)")
                logger.info("Run 'swdeploy build \(project.rawValue) \(device.rawValue)' first")
                throw ExitCode.failure
            }

            let installResult = installApp(appPath: appPath, device: device)

            if installResult {
                logger.info("Installation completed successfully!")
            } else {
                logger.error("Installation failed!")
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - SwiftDeploy.Deploy

extension SwiftDeploy {
    struct Deploy: ParsableCommand {
        // MARK: Static Properties

        static let configuration: CommandConfiguration = .init(
            abstract: "Build and install an app to a device (default command)",
        )

        // MARK: Properties

        @Argument(help: "The project to deploy (prism, whomix, polyplayer)")
        var project: Project

        @Argument(help: "The target device (iphone, ipad, macos)")
        var device: Device

        @Flag(name: .shortAndLong, help: "Show verbose build output")
        var verbose = false

        // MARK: Functions

        func run() throws {
            logger.info("🚀 Deploying \(project.displayName) to \(device.displayName)")

            // Step 1: Build
            logger.info("Step 1: Building...")
            let buildResult = buildProject(project: project, device: device, verbose: verbose)

            guard buildResult.success else {
                logger.error("Build failed!")
                throw ExitCode.failure
            }

            logger.info("Build completed!")

            // Step 2: Install (if applicable)
            if device.canInstall {
                logger.info("Step 2: Installing...")

                guard let appPath = buildResult.appPath else {
                    logger.error("Could not determine app path")
                    throw ExitCode.failure
                }

                let installResult = installApp(appPath: appPath, device: device)

                if installResult {
                    logger.info("Installation completed!")
                } else {
                    logger.error("Installation failed!")
                    throw ExitCode.failure
                }
            } else {
                logger.info("Skipping installation for macOS (app is ready to run from DerivedData)")
                if let appPath = buildResult.appPath {
                    logger.info("App location: \(appPath)")
                }
            }

            logger.info("🎉 Deployment complete!")
        }
    }
}

// MARK: - BuildResult

struct BuildResult {
    let success: Bool
    let appPath: String?
}

func buildProject(project: Project, device: Device, verbose: Bool) -> BuildResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")

    var arguments = [
        "-scheme",
        project.schemeName,
        "-configuration",
        "Debug",
        "-workspace",
        project.workspacePath,
        "-destination",
        device.xcodebuildDestination,
        "-allowProvisioningUpdates",
        "build",
    ]

    // Suppress output unless verbose mode
    if !verbose {
        arguments.append("-quiet")
    }

    process.arguments = arguments

    // Capture output
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = verbose ? FileHandle.standardOutput : outputPipe
    process.standardError = verbose ? FileHandle.standardError : errorPipe

    do {
        try process.run()
        process.waitUntilExit()

        let success = process.terminationStatus == 0
        let appPath = success ? project.appPath(for: device) : nil

        return BuildResult(success: success, appPath: appPath)
    } catch {
        logger.error("Failed to run xcodebuild: \(error)")
        return BuildResult(success: false, appPath: nil)
    }
}

func installApp(appPath: String, device: Device) -> Bool {
    guard let deviceID = device.deviceID else {
        logger.error("No device ID available for \(device.displayName)")
        return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "devicectl",
        "device",
        "install",
        "app",
        "--device",
        deviceID,
        appPath,
    ]

    // Show install output
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    do {
        try process.run()
        process.waitUntilExit()

        return process.terminationStatus == 0
    } catch {
        logger.error("Failed to run xcrun devicectl: \(error)")
        return false
    }
}
