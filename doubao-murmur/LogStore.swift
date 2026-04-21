import Foundation
import os

enum LogStore {
    private static let queue = DispatchQueue(label: "voiceinput.log.store", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let subsystem = AppEnvironment.bundleIdentifier
    static var fileURL: URL {
        AppEnvironment.logsDirectoryURL.appendingPathComponent("voiceinput.log")
    }

    static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func bootstrap() {
        _ = AppEnvironment.ensureLogsDirectoryExists()
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        write("[bootstrap] log ready at \(fileURL.path)")
    }

    static func write(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) \(message)\n"
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

struct AppLog {
    private let logger: Logger
    private let category: String

    init(category: String) {
        logger = LogStore.logger(category: category)
        self.category = category
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogStore.write("[INFO][\(category)] \(message)")
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        LogStore.write("[NOTICE][\(category)] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogStore.write("[ERROR][\(category)] \(message)")
    }
}
