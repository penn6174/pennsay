import Foundation
import Cocoa

class HotkeyManager {
    enum HotkeyEvent {
        case toggleRecording
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false
    private var otherKeyPressed = false
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.3

    init() {
        requestAccessibilityPermission()
    }

    func start() {
        let trusted = AXIsProcessTrusted()
        print("[HotkeyManager] Accessibility trusted: \(trusted)")

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyManager] ❌ Failed to create event tap. Accessibility permission may be needed.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyManager] ✅ Event tap started successfully")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("[HotkeyManager] Accessibility permission not granted. Please enable it in System Settings > Privacy & Security > Accessibility.")
        }
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable the tap
            print("[HotkeyManager] ⚠️ Event tap was disabled (type=\(type.rawValue)), re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Track that another key was pressed while right option is down
            if rightOptionDown {
                otherKeyPressed = true
            }

            // ESC key
            if keyCode == 53 {
                onHotkeyEvent?(.cancel)
                return nil // Consume ESC when we handle it
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        // Right Option key: keycode 61
        let isRightOption = keycode == 61

        if isRightOption {
            let isOptionDown = flags.contains(.maskAlternate)

            if isOptionDown && !rightOptionDown {
                // Right Option pressed down
                rightOptionDown = true
                otherKeyPressed = false
                print("[HotkeyManager] Right Option ↓ (keycode=\(keycode), flags=\(flags.rawValue))")
            } else if !isOptionDown && rightOptionDown {
                // Right Option released
                rightOptionDown = false
                print("[HotkeyManager] Right Option ↑ (otherKeyPressed=\(otherKeyPressed))")

                if !otherKeyPressed {
                    // Clean press-and-release with no other keys
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastToggleTime > debounceInterval {
                        lastToggleTime = now
                        print("[HotkeyManager] 🎤 Firing toggleRecording (handler set: \(onHotkeyEvent != nil))")
                        onHotkeyEvent?(.toggleRecording)
                    } else {
                        print("[HotkeyManager] Debounced (interval=\(now - lastToggleTime)s)")
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}

// C callback for CGEvent tap
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type, event)
}
