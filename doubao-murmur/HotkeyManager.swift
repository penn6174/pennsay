import Cocoa

final class HotkeyManager {
    enum HotkeyEvent {
        case startRecording
        case stopRecording
        case toggleRecording
        case cancel
    }

    private final class RuntimeSlot {
        let id: ShortcutSlotIdentifier
        var shortcut: ShortcutTriggerSlot
        var triggerKeyIsDown = false
        var triggerPressStartTime: TimeInterval = 0
        var holdStarted = false
        var pendingHoldStart: DispatchWorkItem?
        var otherKeyPressedWhileDown = false
        var waitingForSecondTap = false
        var secondTapTimeoutWorkItem: DispatchWorkItem?

        init(id: ShortcutSlotIdentifier, shortcut: ShortcutTriggerSlot) {
            self.id = id
            self.shortcut = shortcut
        }

        func cancelTransientState() {
            triggerKeyIsDown = false
            holdStarted = false
            waitingForSecondTap = false
            otherKeyPressedWhileDown = false
            pendingHoldStart?.cancel()
            pendingHoldStart = nil
            secondTapTimeoutWorkItem?.cancel()
            secondTapTimeoutWorkItem = nil
        }
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private let log = AppLog(category: "Hotkey")
    private var configuration: ShortcutConfiguration
    private var runtimeSlots: [RuntimeSlot] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0
    private let maxTapRetries = 30
    private var shouldConsumeEscape = false

    init(configuration: ShortcutConfiguration) {
        self.configuration = configuration.normalizedForRuntime()
        rebuildRuntimeSlots()
        requestAccessibilityPermission()
    }

    func start() {
        if tryCreateEventTap() {
            tapRetryCount = 0
            return
        }

        requestAccessibilityPermission()
        startPollingForEventTap()
    }

    func stop() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        cancelTransientState()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func updateConfiguration(_ configuration: ShortcutConfiguration) {
        let normalized = configuration.normalizedForRuntime()
        log.notice("shortcut updated primary=\(normalized.primary.displaySummary) secondary=\(normalized.secondary.displaySummary) doubleTap=\(normalized.doubleTapWindowMs)")
        self.configuration = normalized
        rebuildRuntimeSlots()
    }

    func setEscapeHandlingEnabled(_ isEnabled: Bool) {
        shouldConsumeEscape = isEnabled
    }

    fileprivate func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 53 {
            guard shouldConsumeEscape else {
                return Unmanaged.passRetained(event)
            }
            onHotkeyEvent?(.cancel)
            return nil
        }

        for slot in runtimeSlots {
            if slot.waitingForSecondTap, keyCode != slot.shortcut.triggerKey.keyCode {
                slot.waitingForSecondTap = false
                slot.secondTapTimeoutWorkItem?.cancel()
                slot.secondTapTimeoutWorkItem = nil
                log.notice("double tap cancelled slot=\(slot.id.rawValue) keyCode=\(keyCode)")
            }

            if slot.triggerKeyIsDown, keyCode != slot.shortcut.triggerKey.keyCode {
                slot.otherKeyPressedWhileDown = true
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let matchingSlots = runtimeSlots.filter { $0.shortcut.triggerKey.keyCode == keyCode }
        guard !matchingSlots.isEmpty else {
            return Unmanaged.passRetained(event)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        for slot in matchingSlots {
            let isDown = keyIsDown(for: slot.shortcut.triggerKey, flags: event.flags)
            if isDown {
                handleTriggerDown(slot, at: timestamp)
            } else {
                handleTriggerUp(slot, at: timestamp)
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func handleTriggerDown(_ slot: RuntimeSlot, at timestamp: TimeInterval) {
        guard !slot.triggerKeyIsDown else { return }
        slot.triggerKeyIsDown = true
        slot.triggerPressStartTime = timestamp
        slot.otherKeyPressedWhileDown = false
        log.notice("trigger down slot=\(slot.id.rawValue) key=\(slot.shortcut.triggerKey.rawValue) mode=\(slot.shortcut.mode.rawValue)")

        switch slot.shortcut.mode {
        case .hold:
            slot.holdStarted = true
            onHotkeyEvent?(.startRecording)
        case .none, .singleTapToggle, .doubleTapToggle:
            break
        }
    }

    private func handleTriggerUp(_ slot: RuntimeSlot, at timestamp: TimeInterval) {
        guard slot.triggerKeyIsDown else { return }
        slot.triggerKeyIsDown = false
        slot.pendingHoldStart?.cancel()
        slot.pendingHoldStart = nil

        let pressDuration = timestamp - slot.triggerPressStartTime
        log.notice("trigger up slot=\(slot.id.rawValue) mode=\(slot.shortcut.mode.rawValue) duration=\(pressDuration) waitingSecondTap=\(slot.waitingForSecondTap)")
        defer {
            slot.holdStarted = false
        }

        switch slot.shortcut.mode {
        case .none:
            break
        case .hold:
            if slot.holdStarted {
                if pressDuration < 0.08 {
                    log.notice("hold cancelled as accidental press slot=\(slot.id.rawValue) duration=\(pressDuration)")
                    onHotkeyEvent?(.cancel)
                } else {
                    onHotkeyEvent?(.stopRecording)
                }
            } else if pressDuration < 0.08 {
                log.notice("hold ignored as accidental press slot=\(slot.id.rawValue) duration=\(pressDuration)")
            }
        case .singleTapToggle:
            guard !slot.otherKeyPressedWhileDown else { return }
            onHotkeyEvent?(.toggleRecording)
        case .doubleTapToggle:
            guard !slot.otherKeyPressedWhileDown else { return }
            if slot.waitingForSecondTap {
                slot.waitingForSecondTap = false
                slot.secondTapTimeoutWorkItem?.cancel()
                slot.secondTapTimeoutWorkItem = nil
                log.notice("double tap recognized slot=\(slot.id.rawValue)")
                onHotkeyEvent?(.toggleRecording)
            } else {
                slot.waitingForSecondTap = true
                log.notice("double tap armed slot=\(slot.id.rawValue) window=\(configuration.doubleTapWindowMs)")
                let timeout = DispatchWorkItem { [weak self, weak slot] in
                    guard let self, let slot else { return }
                    self.log.notice("double tap window expired slot=\(slot.id.rawValue)")
                    slot.waitingForSecondTap = false
                }
                slot.secondTapTimeoutWorkItem = timeout
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(configuration.doubleTapWindowMs),
                    execute: timeout
                )
            }
        }
    }

    private func keyIsDown(for triggerKey: ShortcutTriggerKey, flags: CGEventFlags) -> Bool {
        switch triggerKey {
        case .rightOption, .leftOption:
            return flags.contains(.maskAlternate)
        case .rightCommand, .leftCommand:
            return flags.contains(.maskCommand)
        case .rightControl:
            return flags.contains(.maskControl)
        case .capsLock:
            return flags.contains(.maskAlphaShift)
        case .function:
            return flags.contains(.maskSecondaryFn)
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func tryCreateEventTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func startPollingForEventTap() {
        accessibilityPollTimer?.invalidate()
        tapRetryCount = 0
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return }
            self.tapRetryCount += 1
            if self.tryCreateEventTap() || self.tapRetryCount >= self.maxTapRetries {
                timer.invalidate()
            }
        }
    }

    private func rebuildRuntimeSlots() {
        cancelTransientState()
        runtimeSlots = configuration.enabledSlots.map { id, shortcut in
            RuntimeSlot(id: id, shortcut: shortcut)
        }
    }

    private func cancelTransientState() {
        runtimeSlots.forEach { $0.cancelTransientState() }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type, event)
}
