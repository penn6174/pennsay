import AppKit

enum UninstallManager {
    static func uninstallAndQuit() throws {
        let fileManager = FileManager.default
        let appBundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = fileManager.temporaryDirectory.appendingPathComponent("voiceinput-uninstall-\(UUID().uuidString).sh")

        let pathsToDelete = [
            AppEnvironment.appSupportDirectoryURL.path,
            AppEnvironment.preferencesPlistURL.path,
            AppEnvironment.logsDirectoryURL.path,
            appBundlePath,
        ]

        try? KeychainStore.deleteAPIKey()
        UserDefaults.standard.removePersistentDomain(forName: AppEnvironment.bundleIdentifier)

        let deleteCommands = pathsToDelete
            .map { "rm -rf '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")

        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do
          sleep 0.1
        done
        \(deleteCommands)
        rm -f '\(scriptURL.path)'
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()

        NSApp.terminate(nil)
    }
}
