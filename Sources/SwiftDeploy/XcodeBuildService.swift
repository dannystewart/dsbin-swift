import Foundation
import PolyKit

// MARK: - XcodeContainerReference

enum XcodeContainerReference: Sendable, Equatable {
    case workspace(String) // *.xcworkspace
    case project(String) // *.xcodeproj

    var kind: XcodeContainerKind {
        switch self {
        case .workspace: .workspace
        case .project: .project
        }
    }

    var path: String {
        switch self {
        case let .workspace(path): path
        case let .project(path): path
        }
    }
}

// MARK: - XcodeContainerKind

enum XcodeContainerKind: Sendable {
    case project
    case workspace
}

// MARK: - XcodeBuildInvocation

struct XcodeBuildInvocation: Sendable {
    var container: XcodeContainerReference
    var scheme: String
    var configuration: String
    var destination: String? = nil
    var derivedDataPath: String? = nil
    var allowProvisioningUpdates: Bool
    var buildSettingsOverrides: [String: String]
}

// MARK: - XcodeBuildResult

struct XcodeBuildResult: Sendable {
    var success: Bool
    var terminationStatus: Int32
    var derivedDataPathUsed: String? = nil
}

// MARK: - XcodeBuildService

enum XcodeBuildService {
    static func build(
        _ invocation: XcodeBuildInvocation,
        verbose: Bool,
    ) throws -> XcodeBuildResult {
        try self.runXcodebuild(invocation, action: "build", verbose: verbose)
    }

    static func archive(
        _ invocation: XcodeBuildInvocation,
        verbose: Bool,
    ) throws -> XcodeBuildResult {
        try self.runXcodebuild(invocation, action: "archive", verbose: verbose)
    }

    // MARK: Scheme detection (for dev commands)

    static func detectScheme(container: XcodeContainerReference) -> String? {
        let listProcess = Process()
        listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild", "-list", "-json"]
        switch container {
        case let .project(path):
            args += ["-project", path]
        case let .workspace(path):
            args += ["-workspace", path]
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

        struct ContainerInfo: Decodable {
            let name: String?
            let schemes: [String]?
        }
        struct ListOutput: Decodable {
            let project: ContainerInfo?
            let workspace: ContainerInfo?
        }

        guard let output = try? JSONDecoder().decode(ListOutput.self, from: data) else {
            return nil
        }

        let schemes: [String] = switch container {
        case .project: output.project?.schemes ?? []
        case .workspace: output.workspace?.schemes ?? []
        }
        guard !schemes.isEmpty else { return nil }

        let baseName = URL(fileURLWithPath: container.path).deletingPathExtension().lastPathComponent
        return schemes.first(where: { $0 == baseName }) ?? schemes.first
    }

    private static func runXcodebuild(
        _ invocation: XcodeBuildInvocation,
        action: String,
        verbose: Bool,
    ) throws -> XcodeBuildResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild"]
        switch invocation.container {
        case let .workspace(path):
            args += ["-workspace", path]
        case let .project(path):
            args += ["-project", path]
        }

        args += ["-scheme", invocation.scheme]
        args += ["-configuration", invocation.configuration]

        if let destination = invocation.destination {
            args += ["-destination", destination]
        }

        if let derivedDataPath = invocation.derivedDataPath {
            args += ["-derivedDataPath", derivedDataPath]
        }

        if invocation.allowProvisioningUpdates {
            args.append("-allowProvisioningUpdates")
        }

        if !verbose {
            args.append("-quiet")
        }

        // Build setting overrides (e.g. MARKETING_VERSION, CURRENT_PROJECT_VERSION)
        for (k, v) in invocation.buildSettingsOverrides.sorted(by: { $0.key < $1.key }) {
            args.append("\(k)=\(v)")
        }

        args.append(action)

        process.arguments = args

        if verbose {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        } else {
            // In quiet mode, still surface stderr if xcodebuild fails (ArgumentParser will show our error).
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }

        try process.run()
        process.waitUntilExit()

        let success = process.terminationStatus == 0
        return .init(
            success: success,
            terminationStatus: process.terminationStatus,
            derivedDataPathUsed: invocation.derivedDataPath,
        )
    }
}
