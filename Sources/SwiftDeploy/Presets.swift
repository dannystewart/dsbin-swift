import ArgumentParser
import Foundation
import PolyKit

// MARK: - Presets

struct Presets: Codable, Sendable {
    // MARK: Config

    static let defaultConfigPath = "~/.config/swdeploy/presets.json"

    // MARK: Built-ins (current behavior)

    static let builtIn: Presets = .init(
        projects: [
            .init(
                id: "prism",
                displayName: "Prism",
                workspacePath: "/Users/danny/Developer/PrismApp/Prism.xcodeproj/project.xcworkspace",
                projectPath: nil,
                scheme: "Prism",
                configuration: "Debug",
                derivedDataPath: nil,
            ),
            .init(
                id: "whomix",
                displayName: "Whomix",
                workspacePath: "/Users/danny/Developer/Whomix/Whomix.xcodeproj/project.xcworkspace",
                projectPath: nil,
                scheme: "Whomix",
                configuration: "Debug",
                derivedDataPath: nil,
            ),
            .init(
                id: "polyplayer",
                displayName: "PolyPlayer",
                workspacePath: "/Users/danny/Developer/PolyPlayer/PolyPlayer.xcodeproj/project.xcworkspace",
                projectPath: nil,
                scheme: "PolyPlayer",
                configuration: "Debug",
                derivedDataPath: nil,
            ),
        ],
        devices: [
            .init(
                id: "iphone",
                displayName: "iPhone",
                platform: .ios,
                destination: "platform=iOS,id=00008150-001C31440108401C",
                deviceId: "00008150-001C31440108401C",
            ),
            .init(
                id: "ipad",
                displayName: "iPad",
                platform: .ios,
                destination: "platform=iOS,id=00008103-0001694C3EBB001E",
                deviceId: "00008103-0001694C3EBB001E",
            ),
            .init(
                id: "macos",
                displayName: "macOS",
                platform: .macos,
                destination: "platform=macOS,arch=arm64",
                deviceId: nil,
            ),
        ],
    )

    var projects: [ProjectPreset]
    var devices: [DevicePreset]

    static func resolveConfigPath(overridePath: String?) -> String {
        let raw = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (raw?.isEmpty == false) ? raw! : Self.defaultConfigPath
        return expandTilde(in: candidate)
    }

    static func load(from absolutePath: String) throws -> Presets {
        // Start with built-ins, then override/extend with file contents.
        var merged = Self.builtIn

        let fm = FileManager.default
        guard fm.fileExists(atPath: absolutePath) else {
            return merged
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
            let decoded = try JSONDecoder().decode(Presets.self, from: data)
            merged.merge(overrides: decoded)
            return merged
        } catch {
            throw PresetsError.invalidConfig(path: absolutePath, underlying: error)
        }
    }

    mutating func merge(overrides: Presets) {
        // By ID: override replaces built-in entry, otherwise appended.
        var projectByID = Dictionary(uniqueKeysWithValues: self.projects.map { ($0.id, $0) })
        for p in overrides.projects {
            projectByID[p.id] = p
        }
        self.projects = projectByID.values.sorted { $0.id < $1.id }

        var deviceByID = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0) })
        for d in overrides.devices {
            deviceByID[d.id] = d
        }
        self.devices = deviceByID.values.sorted { $0.id < $1.id }
    }

    // MARK: Lookup

    func project(id: String) -> ProjectPreset? {
        self.projects.first(where: { $0.id == id })
    }

    func device(id: String) -> DevicePreset? {
        self.devices.first(where: { $0.id == id })
    }

    func requireProject(id: String, allowMissingIfOverridden: Bool) throws -> ProjectPreset? {
        if let preset = self.project(id: id) {
            return preset
        }
        if allowMissingIfOverridden {
            return nil
        }
        throw PresetsError.unknownProject(id: id, known: self.projects.map(\.id))
    }

    func requireDevice(id: String, allowMissingIfOverridden: Bool) throws -> DevicePreset? {
        if let preset = self.device(id: id) {
            return preset
        }
        if allowMissingIfOverridden {
            return nil
        }
        throw PresetsError.unknownDevice(id: id, known: self.devices.map(\.id))
    }

    func summaryText() -> String {
        func bullet(_ s: String) -> String { "- \(s)" }

        var out = [String]()
        out.append("Projects:")
        for p in self.projects {
            let path = p.workspacePath ?? p.projectPath ?? "<missing-path>"
            out.append(bullet("\(p.id) (\(p.displayName))  scheme=\(p.scheme)  path=\(path)"))
        }

        out.append("")
        out.append("Devices:")
        for d in self.devices {
            let idPart = d.deviceId.map { " deviceId=\($0)" } ?? ""
            out.append(bullet("\(d.id) (\(d.displayName))  platform=\(d.platform.rawValue)  destination=\(d.destination)\(idPart)"))
        }

        return out.joined(separator: "\n")
    }
}

// MARK: - ProjectPreset

struct ProjectPreset: Codable, Sendable {
    let id: String
    let displayName: String
    let workspacePath: String?
    let projectPath: String?
    let scheme: String
    let configuration: String?
    let derivedDataPath: String?

    func resolvedContainer() throws -> XcodeContainerReference {
        if let workspacePath {
            return .workspace(expandTilde(in: workspacePath))
        }
        if let projectPath {
            return .project(expandTilde(in: projectPath))
        }
        throw PresetsError.invalidProjectPreset(id: self.id, message: "Expected workspacePath or projectPath.")
    }
}

// MARK: - PresetPlatform

enum PresetPlatform: String, Codable, Sendable {
    case ios
    case macos
}

// MARK: - DevicePreset

struct DevicePreset: Codable, Sendable {
    let id: String
    let displayName: String
    let platform: PresetPlatform
    let destination: String
    let deviceId: String?
}

// MARK: - PresetsError

enum PresetsError: LoggableError {
    case invalidConfig(path: String, underlying: Error)
    case unknownProject(id: String, known: [String])
    case unknownDevice(id: String, known: [String])
    case invalidProjectPreset(id: String, message: String)

    var logMessage: String {
        switch self {
        case let .invalidConfig(path, underlying):
            return "Could not parse presets config at \(path): \(underlying)"

        case let .unknownProject(id, known):
            let list = known.isEmpty ? "<none>" : known.joined(separator: ", ")
            return "Unknown project preset '\(id)'. Known: \(list)"

        case let .unknownDevice(id, known):
            let list = known.isEmpty ? "<none>" : known.joined(separator: ", ")
            return "Unknown device preset '\(id)'. Known: \(list)"

        case let .invalidProjectPreset(id, message):
            return "Invalid project preset '\(id)': \(message)"
        }
    }
}

// MARK: - Helpers

private func expandTilde(in path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
    return path
}
