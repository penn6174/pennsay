import AppKit

enum NotificationHelper {
    static func show(title: String, body: String) {
#if compiler(>=6.0)
#warning("NSUserNotification is deprecated, but retained here to avoid extra notification permission prompts.")
#endif
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }
}
