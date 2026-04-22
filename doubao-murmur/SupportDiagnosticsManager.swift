import AppKit
import Foundation

@MainActor
final class SupportDiagnosticsManager {
    static let shared = SupportDiagnosticsManager()

    private enum DiagnosticsError: LocalizedError {
        case emailUnavailable
        case archiveCreationFailed

        var errorDescription: String? {
            switch self {
            case .emailUnavailable:
                return "当前系统没有可用的邮件撰写服务。"
            case .archiveCreationFailed:
                return "无法生成诊断日志压缩包。"
            }
        }
    }

    private struct SessionMarker: Codable {
        let launchedAt: Date
        let version: String
        let build: String
    }

    private let log = AppLog(category: "SupportDiagnostics")
    private let fileManager = FileManager.default

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var sessionMarkerURL: URL {
        AppEnvironment.ensureAppSupportDirectoryExists()
            .appendingPathComponent("session-in-progress.json")
    }

    private var diagnosticsRootURL: URL {
        fileManager.temporaryDirectory.appendingPathComponent("PennSaySupport", isDirectory: true)
    }

    @discardableResult
    func beginSession() -> Bool {
        let previousLaunchEndedUnexpectedly = fileManager.fileExists(atPath: sessionMarkerURL.path)
        let marker = SessionMarker(
            launchedAt: Date(),
            version: currentVersion,
            build: currentBuild
        )

        do {
            AppEnvironment.ensureAppSupportDirectoryExists()
            let data = try JSONEncoder().encode(marker)
            try data.write(to: sessionMarkerURL, options: .atomic)
            log.notice("session marker written at launch")
        } catch {
            log.error("failed to write session marker: \(error.localizedDescription)")
        }

        return previousLaunchEndedUnexpectedly
    }

    func markCleanExit() {
        do {
            if fileManager.fileExists(atPath: sessionMarkerURL.path) {
                try fileManager.removeItem(at: sessionMarkerURL)
                log.notice("session marker removed on clean exit")
            }
        } catch {
            log.error("failed to remove session marker: \(error.localizedDescription)")
        }
    }

    func composeSupportEmail(reason: String) throws {
        let archiveURL = try createDiagnosticsArchive(reason: reason)
        guard let service = NSSharingService(named: .composeEmail) else {
            throw DiagnosticsError.emailUnavailable
        }

        service.recipients = [AppEnvironment.supportEmail]
        service.subject = "\(AppEnvironment.displayName) 诊断日志 - \(reason)"
        service.perform(withItems: [composeEmailBody(reason: reason), archiveURL])
        log.notice("opened support email composer with \(archiveURL.lastPathComponent)")
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private func composeEmailBody(reason: String) -> String {
        """
        请描述你遇到的问题（崩溃 / 卡死 / 重启后异常 / 识别错误等）。

        应用：\(AppEnvironment.displayName)
        版本：\(currentVersion) (\(currentBuild))
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        原因：\(reason)
        联系邮箱：\(AppEnvironment.supportEmail)
        """
    }

    private func createDiagnosticsArchive(reason: String) throws -> URL {
        try fileManager.createDirectory(at: diagnosticsRootURL, withIntermediateDirectories: true)

        let stamp = Self.timestampFormatter.string(from: Date())
        let folderName = "PennSay-diagnostics-\(stamp)"
        let folderURL = diagnosticsRootURL.appendingPathComponent(folderName, isDirectory: true)
        let archiveURL = diagnosticsRootURL.appendingPathComponent("\(folderName).zip", isDirectory: false)

        try? fileManager.removeItem(at: folderURL)
        try? fileManager.removeItem(at: archiveURL)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        try writeSummary(to: folderURL.appendingPathComponent("README.txt"), reason: reason)
        try copyIfPresent(from: LogStore.fileURL, toDirectory: folderURL)
        try copyRecentDiagnosticReports(toDirectory: folderURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folderURL.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DiagnosticsError.archiveCreationFailed
        }

        return archiveURL
    }

    private func writeSummary(to url: URL, reason: String) throws {
        let text = """
        App: \(AppEnvironment.displayName)
        Version: \(currentVersion) (\(currentBuild))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Generated At: \(ISO8601DateFormatter().string(from: Date()))
        Reason: \(reason)
        Support Email: \(AppEnvironment.supportEmail)
        Logs Directory: \(AppEnvironment.logsDirectoryURL.path)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyIfPresent(from sourceURL: URL, toDirectory directoryURL: URL) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        let destinationURL = directoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func copyRecentDiagnosticReports(toDirectory directoryURL: URL) throws {
        let reportsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DiagnosticReports", isDirectory: true)

        guard fileManager.fileExists(atPath: reportsURL.path) else { return }

        let reportURLs = try fileManager.contentsOfDirectory(
            at: reportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("pennsay")
                && (name.hasSuffix(".crash") || name.hasSuffix(".hang") || name.hasSuffix(".ips"))
        }
        .sorted {
            let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        .prefix(3)

        for reportURL in reportURLs {
            try copyIfPresent(from: reportURL, toDirectory: directoryURL)
        }
    }
}
