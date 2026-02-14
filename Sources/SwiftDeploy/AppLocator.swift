import Foundation

// MARK: - AppLocator

enum AppLocator {
    /// Locates a built .app bundle for an Xcode build.
    ///
    /// This prefers a provided derived data path, but can fall back to scanning the default
    /// DerivedData root for recent builds that contain the expected product.
    static func locateAppBundle(
        productName: String,
        configuration: String,
        platform: PresetPlatform,
        derivedDataPath: String?,
    ) -> String? {
        let fm = FileManager.default

        // If caller provided an explicit DerivedData path, try deterministic paths first.
        if let derivedDataPath {
            let bundle = self.appBundlePath(
                derivedDataRootOrProject: derivedDataPath,
                productName: productName,
                configuration: configuration,
                platform: platform,
            )
            if fm.fileExists(atPath: bundle) {
                return bundle
            }
        }

        // Fall back to scanning the global DerivedData directory.
        let globalRoot = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
        guard let candidates = try? fm.contentsOfDirectory(atPath: globalRoot) else {
            return nil
        }

        for item in candidates where item.localizedCaseInsensitiveContains(productName) {
            let base = "\(globalRoot)/\(item)"
            let bundle = appBundlePath(
                derivedDataRootOrProject: base,
                productName: productName,
                configuration: configuration,
                platform: platform,
            )
            if fm.fileExists(atPath: bundle) {
                return bundle
            }
        }

        return nil
    }

    /// Locates an executable to run/link (macOS app executable or CLI product) from DerivedData.
    static func locateRunnableExecutable(
        productName: String,
        configuration: String,
        derivedDataPath: String?,
    ) -> String? {
        let fm = FileManager.default

        func execCandidates(derivedDataBase: String) -> [String] {
            [
                // macOS app bundle executable
                "\(derivedDataBase)/Build/Products/\(configuration)/\(productName).app/Contents/MacOS/\(productName)",
                // CLI product placed directly in Products
                "\(derivedDataBase)/Build/Products/\(configuration)/\(productName)",
            ]
        }

        if let derivedDataPath {
            for candidate in execCandidates(derivedDataBase: derivedDataPath) where fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        let globalRoot = "\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData"
        guard let candidates = try? fm.contentsOfDirectory(atPath: globalRoot) else {
            return nil
        }

        for item in candidates where item.localizedCaseInsensitiveContains(productName) {
            let base = "\(globalRoot)/\(item)"
            for candidate in execCandidates(derivedDataBase: base) where fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // Fallback to local SPM-style build dirs when used outside Xcode.
        let cwd = FileManager.default.currentDirectoryPath
        let local = [
            "\(cwd)/.build/\(configuration.lowercased())/\(productName)",
            "\(cwd)/build/\(configuration.lowercased())/\(productName)",
        ]
        for candidate in local where fm.fileExists(atPath: candidate) {
            return candidate
        }

        return nil
    }

    private static func appBundlePath(
        derivedDataRootOrProject: String,
        productName: String,
        configuration: String,
        platform: PresetPlatform,
    ) -> String {
        switch platform {
        case .macos:
            "\(derivedDataRootOrProject)/Build/Products/\(configuration)/\(productName).app"
        case .ios:
            // Device builds land under Debug-iphoneos / Release-iphoneos.
            "\(derivedDataRootOrProject)/Build/Products/\(configuration)-iphoneos/\(productName).app"
        }
    }
}
