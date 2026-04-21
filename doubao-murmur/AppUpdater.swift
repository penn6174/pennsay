import AppKit

enum AppUpdater {
    static func openReleasePage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
