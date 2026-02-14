import ArgumentParser
import Foundation
import PolyKit

// MARK: - SwiftDeploy.Build

extension SwiftDeploy {
    struct Build: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "build",
            abstract: "Build an app for a device/platform using presets (or overrides).",
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Project preset id (e.g. prism, whomix, polyplayer).")
        var projectID: String

        @Argument(help: "Device preset id (e.g. iphone, ipad, macos).")
        var deviceID: String

        @Flag(name: .shortAndLong, help: "Show verbose build output.")
        var verbose = false

        /// Project overrides
        @Option(name: .long, help: "Override workspace path (*.xcworkspace).")
        var workspacePath: String?

        @Option(name: .long, help: "Override project path (*.xcodeproj).")
        var projectPath: String?

        @Option(name: .long, help: "Override scheme name.")
        var scheme: String?

        @Option(name: .long, help: "Override build configuration (Debug/Release).")
        var configuration: String?

        @Option(name: .long, help: "Override derived data path (xcodebuild -derivedDataPath).")
        var derivedDataPath: String?

        /// Device overrides
        @Option(name: .long, help: "Override xcodebuild destination (xcodebuild -destination).")
        var destination: String?

        @Option(name: .long, help: "Override device ID for devicectl install.")
        var deviceId: String?

        func run() throws {
            let presets = try SwiftDeploy.loadPresets(configPathOverride: self.global.config)

            let resolvedProject = try resolveProject(presets: presets)
            let resolvedDevice = try resolveDevice(presets: presets)

            SwiftDeploy.printInfo("Building \(resolvedProject.displayName) for \(resolvedDevice.displayName)...")

            let build = try XcodeBuildService.build(
                .init(
                    container: resolvedProject.container,
                    scheme: resolvedProject.scheme,
                    configuration: resolvedProject.configuration,
                    destination: resolvedDevice.destination,
                    derivedDataPath: resolvedProject.derivedDataPath,
                    allowProvisioningUpdates: true,
                    buildSettingsOverrides: [:],
                ),
                verbose: self.verbose,
            )

            guard build.success else {
                SwiftDeploy.printError("Build failed (exit code \(build.terminationStatus)).")
                throw ExitCode.failure
            }

            SwiftDeploy.printInfo("Build completed successfully.")

            let appPath = AppLocator.locateAppBundle(
                productName: resolvedProject.productName,
                configuration: resolvedProject.configuration,
                platform: resolvedDevice.platform,
                derivedDataPath: build.derivedDataPathUsed ?? resolvedProject.derivedDataPath,
            )

            if let appPath {
                SwiftDeploy.printInfo("App location: \(appPath)")
            } else {
                SwiftDeploy.printWarning("Built successfully, but could not locate the .app in DerivedData.")
            }
        }

        private func resolveProject(presets: Presets) throws -> ResolvedProject {
            let hasOverrides =
                (self.workspacePath?.isEmpty == false)
                    || (self.projectPath?.isEmpty == false)
                    || (self.scheme?.isEmpty == false)

            let preset = try presets.requireProject(id: self.projectID, allowMissingIfOverridden: hasOverrides)

            let container: XcodeContainerReference
            if let workspacePath, !workspacePath.isEmpty {
                container = .workspace(expandTilde(in: workspacePath))
            } else if let projectPath, !projectPath.isEmpty {
                container = .project(expandTilde(in: projectPath))
            } else if let preset {
                container = try preset.resolvedContainer()
            } else {
                throw PresetsError.invalidProjectPreset(id: self.projectID, message: "Missing preset and no --workspace-path/--project-path provided.")
            }

            let scheme = self.scheme?.isEmpty == false
                ? self.scheme!
                : (preset?.scheme ?? XcodeBuildService.detectScheme(container: container) ?? "")

            guard !scheme.isEmpty else {
                throw PresetsError.invalidProjectPreset(id: self.projectID, message: "Could not determine scheme. Provide --scheme.")
            }

            let config = self.configuration ?? preset?.configuration ?? "Debug"
            let derived = self.derivedDataPath ?? preset?.derivedDataPath

            return .init(
                id: self.projectID,
                displayName: preset?.displayName ?? scheme,
                productName: scheme,
                container: container,
                scheme: scheme,
                configuration: config,
                derivedDataPath: derived.map { expandTilde(in: $0) },
            )
        }

        private func resolveDevice(presets: Presets) throws -> ResolvedDevice {
            let hasOverrides = (self.destination?.isEmpty == false)
            let preset = try presets.requireDevice(id: self.deviceID, allowMissingIfOverridden: hasOverrides)

            let destination = self.destination ?? preset?.destination
            guard let destination, !destination.isEmpty else {
                throw PresetsError.invalidProjectPreset(id: self.deviceID, message: "Could not determine destination. Provide --destination.")
            }

            let platform = preset?.platform ?? inferPlatform(from: destination)
            let deviceId = self.deviceId ?? preset?.deviceId

            return .init(
                id: self.deviceID,
                displayName: preset?.displayName ?? self.deviceID,
                platform: platform,
                destination: destination,
                deviceId: deviceId,
            )
        }
    }
}

// MARK: - SwiftDeploy.Install

extension SwiftDeploy {
    struct Install: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "install",
            abstract: "Install a previously-built app to a device using presets (or overrides).",
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Project preset id (e.g. prism, whomix, polyplayer).")
        var projectID: String

        @Argument(help: "Device preset id (e.g. iphone, ipad).")
        var deviceID: String

        @Option(name: .long, help: "Override derived data path (xcodebuild -derivedDataPath).")
        var derivedDataPath: String?

        @Option(name: .long, help: "Override device ID for devicectl install.")
        var deviceId: String?

        @Option(name: .long, help: "Override xcodebuild destination (xcodebuild -destination).")
        var destination: String?

        @Option(name: .long, help: "Override build configuration (Debug/Release).")
        var configuration: String?

        func run() throws {
            let presets = try SwiftDeploy.loadPresets(configPathOverride: self.global.config)

            let projectPreset = try presets.requireProject(id: self.projectID, allowMissingIfOverridden: false)!
            let devicePreset = try presets.requireDevice(id: self.deviceID, allowMissingIfOverridden: self.destination?.isEmpty == false)

            let platform = devicePreset?.platform ?? inferPlatform(from: self.destination ?? "")
            guard platform == .ios else {
                SwiftDeploy.printError("Cannot install to macOS - installation only supported for iOS devices.")
                throw ExitCode.failure
            }

            let resolvedDeviceId = self.deviceId ?? devicePreset?.deviceId
            guard let resolvedDeviceId, !resolvedDeviceId.isEmpty else {
                SwiftDeploy.printError("No device ID available. Provide it via presets or --device-id.")
                throw ExitCode.failure
            }

            let config = self.configuration ?? projectPreset.configuration ?? "Debug"
            let derived = self.derivedDataPath ?? projectPreset.derivedDataPath

            let appPath = AppLocator.locateAppBundle(
                productName: projectPreset.scheme,
                configuration: config,
                platform: .ios,
                derivedDataPath: derived.map { Presets.resolveConfigPath(overridePath: $0) },
            )

            guard let appPath else {
                SwiftDeploy.printError("App not found in DerivedData. Run 'swdeploy build \(self.projectID) \(self.deviceID)' first.")
                throw ExitCode.failure
            }

            SwiftDeploy.printInfo("Installing \(projectPreset.displayName) to \(devicePreset?.displayName ?? self.deviceID)...")
            let ok = installApp(appPath: appPath, deviceId: resolvedDeviceId)
            guard ok else {
                SwiftDeploy.printError("Installation failed.")
                throw ExitCode.failure
            }
            SwiftDeploy.printInfo("Installation completed successfully.")
        }
    }
}

// MARK: - SwiftDeploy.Deploy

extension SwiftDeploy {
    struct Deploy: ParsableCommand {
        static let configuration: CommandConfiguration = .init(
            commandName: "deploy",
            abstract: "Build and (if applicable) install an app to a device (default command).",
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Project preset id (e.g. prism, whomix, polyplayer).")
        var projectID: String

        @Argument(help: "Device preset id (e.g. iphone, ipad, macos).")
        var deviceID: String

        @Flag(name: .shortAndLong, help: "Show verbose build output.")
        var verbose = false

        @Option(name: .long, help: "Override build configuration (Debug/Release).")
        var configuration: String?

        func run() throws {
            let presets = try SwiftDeploy.loadPresets(configPathOverride: self.global.config)

            guard let projectPreset = presets.project(id: self.projectID) else {
                SwiftDeploy.printError("Unknown project preset '\(self.projectID)'. Run 'swdeploy presets list'.")
                throw ExitCode.failure
            }

            guard let devicePreset = presets.device(id: self.deviceID) else {
                SwiftDeploy.printError("Unknown device preset '\(self.deviceID)'. Run 'swdeploy presets list'.")
                throw ExitCode.failure
            }

            let container = try projectPreset.resolvedContainer()
            let config = self.configuration ?? projectPreset.configuration ?? "Debug"

            SwiftDeploy.printInfo("Deploying \(projectPreset.displayName) to \(devicePreset.displayName)...")
            SwiftDeploy.printInfo("Step 1: Building...")

            let build = try XcodeBuildService.build(
                .init(
                    container: container,
                    scheme: projectPreset.scheme,
                    configuration: config,
                    destination: devicePreset.destination,
                    derivedDataPath: projectPreset.derivedDataPath.map { expandTilde(in: $0) },
                    allowProvisioningUpdates: true,
                    buildSettingsOverrides: [:],
                ),
                verbose: self.verbose,
            )

            guard build.success else {
                SwiftDeploy.printError("Build failed (exit code \(build.terminationStatus)).")
                throw ExitCode.failure
            }

            SwiftDeploy.printInfo("Build completed.")

            let appPath = AppLocator.locateAppBundle(
                productName: projectPreset.scheme,
                configuration: config,
                platform: devicePreset.platform,
                derivedDataPath: build.derivedDataPathUsed ?? projectPreset.derivedDataPath.map { expandTilde(in: $0) },
            )

            if devicePreset.platform == .macos {
                SwiftDeploy.printInfo("Skipping installation for macOS (app is ready to run from DerivedData).")
                if let appPath {
                    SwiftDeploy.printInfo("App location: \(appPath)")
                }
                SwiftDeploy.printInfo("Deployment complete.")
                return
            }

            SwiftDeploy.printInfo("Step 2: Installing...")

            guard let deviceId = devicePreset.deviceId, !deviceId.isEmpty else {
                SwiftDeploy.printError("No device ID available for \(devicePreset.displayName).")
                throw ExitCode.failure
            }

            guard let appPath else {
                SwiftDeploy.printError("Could not locate the built .app in DerivedData; cannot install.")
                throw ExitCode.failure
            }

            guard installApp(appPath: appPath, deviceId: deviceId) else {
                SwiftDeploy.printError("Installation failed.")
                throw ExitCode.failure
            }

            SwiftDeploy.printInfo("Installation completed.")
            SwiftDeploy.printInfo("Deployment complete.")
        }
    }
}

// MARK: - SwiftDeploy.PresetsCommand

extension SwiftDeploy {
    struct PresetsCommand: ParsableCommand {
        struct List: ParsableCommand {
            static let configuration: CommandConfiguration = .init(
                commandName: "list",
                abstract: "List project and device presets.",
            )

            @OptionGroup var global: GlobalOptions

            func run() throws {
                let presets = try SwiftDeploy.loadPresets(configPathOverride: self.global.config)
                print(presets.summaryText())
            }
        }

        static let configuration: CommandConfiguration = .init(
            commandName: "presets",
            abstract: "Inspect swdeploy presets.",
            subcommands: [List.self],
            defaultSubcommand: List.self,
        )
    }
}

// MARK: - ResolvedProject

private struct ResolvedProject {
    let id: String
    let displayName: String
    let productName: String
    let container: XcodeContainerReference
    let scheme: String
    let configuration: String
    let derivedDataPath: String?
}

// MARK: - ResolvedDevice

private struct ResolvedDevice {
    let id: String
    let displayName: String
    let platform: PresetPlatform
    let destination: String
    let deviceId: String?
}

private func inferPlatform(from destination: String) -> PresetPlatform {
    if destination.localizedCaseInsensitiveContains("platform=macos") {
        return .macos
    }
    return .ios
}

private func installApp(appPath: String, deviceId: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "devicectl",
        "device",
        "install",
        "app",
        "--device",
        deviceId,
        appPath,
    ]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        SwiftDeploy.printError("Failed to run xcrun devicectl: \(error)")
        return false
    }
}

private func expandTilde(in path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
    return path
}
