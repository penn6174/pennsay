import Foundation
import AppKit

struct PasteHelper {
    static func copyAndPaste(_ text: String, targetApplication: NSRunningApplication?) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let existingItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { partial, type in
                partial[type] = item.data(forType: type)
            }
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let targetApplication {
            targetApplication.activate(options: [.activateAllWindows])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulatePaste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                restorePasteboard(items: existingItems)
            }
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: ⌘V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V
        keyDown?.flags = .maskCommand

        // Key up: ⌘V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func restorePasteboard(items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems: [NSPasteboardItem] = items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
