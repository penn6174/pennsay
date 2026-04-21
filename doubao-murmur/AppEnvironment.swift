import Foundation

enum AppEnvironment {
    static let appName = "PennSay"
    static let displayName = "PennSay"
    static let bundleIdentifier = "com.voiceinput.app"
    static let appSupportDirectoryName = "DoubaoMurmur"
    static let logsDirectoryName = "DoubaoMurmur"
    static let githubRepoOwner = "penn6174"
    static let githubRepoName = "pennsay"
    static let madeByLine = "Made by PENN"
    static let listeningPlaceholder = "\(displayName) 正在聆听…"
    static let refiningPlaceholder = "\(displayName) 正在润色…"

    static var appSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    static var logsDirectoryURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Logs", isDirectory: true)
       	    .appendingPathComponent(logsDirectoryName, isDirectory: true)
    }

    static var preferencesPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
    }

    @discardableResult
    static func ensureAppSupportDirectoryExists() -> URL {
        let url = appSupportDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func ensureLogsDirectoryExists() -> URL {
        let url = logsDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
