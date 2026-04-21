import AppKit
import Foundation

@MainActor
final class AppUpdater {
    enum PreparationResult {
        case prepared
        case alreadyPrepared
    }

    enum UpdateError: LocalizedError {
        case missingZipAsset
        case bundlePathUnavailable
        case destinationNotWritable
        case unzipFailed
        case extractedAppMissing

        var errorDescription: String? {
            switch self {
            case .missingZipAsset:
                return "更新包缺少 ZIP 资源。"
            case .bundlePathUnavailable:
                return "当前应用路径不可用。"
            case .destinationNotWritable:
                return "当前应用安装目录不可写，无法后台准备更新。"
            case .unzipFailed:
                return "解压更新包失败。"
            case .extractedAppMissing:
                return "更新包中未找到应用程序。"
            }
        }
    }

    private enum Keys {
        static let preparedTag = "updater.preparedTag"
    }

    static let shared = AppUpdater()

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let log = AppLog(category: "AppUpdater")

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        clearPreparedStateIfCurrentVersionMatches()
    }

    static func openReleasePage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func canPrepareSilently(for release: ReleaseInfo) -> Bool {
        guard release.zipAssetURL != nil else { return false }
        guard let appBundleURL = Bundle.main.bundleURL.standardizedFileURL as URL?,
              let parentURL = appBundleURL.deletingLastPathComponent() as URL? else {
            return false
        }
        return fileManager.isWritableFile(atPath: parentURL.path)
    }

    func prepareUpdateIfNeeded(release: ReleaseInfo) async throws -> PreparationResult {
        guard let zipAssetURL = release.zipAssetURL else {
            throw UpdateError.missingZipAsset
        }
        guard let appBundleURL = Bundle.main.bundleURL.standardizedFileURL as URL? else {
            throw UpdateError.bundlePathUnavailable
        }

        let parentURL = appBundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parentURL.path) else {
            throw UpdateError.destinationNotWritable
        }

        if defaults.string(forKey: Keys.preparedTag) == release.tag {
            return .alreadyPrepared
        }

        let stagingRoot = AppEnvironment.ensureAppSupportDirectoryExists()
            .appendingPathComponent("PreparedUpdates", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let releaseDirectory = stagingRoot.appendingPathComponent(release.tag, isDirectory: true)
        try? fileManager.removeItem(at: releaseDirectory)
        try fileManager.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)

        let zipPath = releaseDirectory.appendingPathComponent("release.zip", isDirectory: false)
        let unzipDirectory = releaseDirectory.appendingPathComponent("unzipped", isDirectory: true)
        try fileManager.createDirectory(at: unzipDirectory, withIntermediateDirectories: true)

        let (downloadedFileURL, _) = try await URLSession.shared.download(from: zipAssetURL)
        try? fileManager.removeItem(at: zipPath)
        try fileManager.moveItem(at: downloadedFileURL, to: zipPath)

        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzipProcess.arguments = ["-x", "-k", zipPath.path, unzipDirectory.path]
        try unzipProcess.run()
        unzipProcess.waitUntilExit()
        guard unzipProcess.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let extractedAppURL = try findExtractedApp(in: unzipDirectory)
        let stagedAppURL = releaseDirectory.appendingPathComponent("PennSay.app", isDirectory: true)
        try? fileManager.removeItem(at: stagedAppURL)
        try fileManager.moveItem(at: extractedAppURL, to: stagedAppURL)

        let installerScriptURL = releaseDirectory.appendingPathComponent("install-on-quit.sh", isDirectory: false)
        try writeInstallerScript(
            to: installerScriptURL,
            stagedAppURL: stagedAppURL,
            targetAppURL: appBundleURL,
            releaseDirectory: releaseDirectory
        )

        let installerProcess = Process()
        installerProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        installerProcess.arguments = [installerScriptURL.path]
        try installerProcess.run()

        defaults.set(release.tag, forKey: Keys.preparedTag)
        log.notice("prepared update \(release.tag) for install on next app restart")
        return .prepared
    }

    private func clearPreparedStateIfCurrentVersionMatches() {
        guard let preparedTag = defaults.string(forKey: Keys.preparedTag) else { return }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let normalizedPreparedVersion = preparedTag.hasPrefix("v")
            ? String(preparedTag.dropFirst())
            : preparedTag
        if normalizedPreparedVersion == currentVersion {
            defaults.removeObject(forKey: Keys.preparedTag)
        }
    }

    private func findExtractedApp(in directory: URL) throws -> URL {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "app" {
                return item
            }
        }

        throw UpdateError.extractedAppMissing
    }

    private func writeInstallerScript(
        to scriptURL: URL,
        stagedAppURL: URL,
        targetAppURL: URL,
        releaseDirectory: URL
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail

        while kill -0 \(pid) 2>/dev/null; do
          sleep 1
        done

        rm -rf "\(targetAppURL.path)"
        mv "\(stagedAppURL.path)" "\(targetAppURL.path)"

        # Mirror Homebrew cask postflight: strip quarantine xattr so Gatekeeper
        # trusts the freshly-copied ad-hoc signed bundle, and reset Accessibility
        # TCC so the new signature hash re-registers instead of silently failing
        # with stale authorization records.
        /usr/bin/xattr -dr com.apple.quarantine "\(targetAppURL.path)" 2>/dev/null || true
        /usr/bin/tccutil reset Accessibility com.voiceinput.app 2>/dev/null || true

        rm -rf "\(releaseDirectory.path)"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
