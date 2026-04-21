import Cocoa

final class HotkeyManager {
    enum HotkeyEvent {
        case startRecording
        case stopRecording
        case toggleRecording
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private let log = AppLog(category: "Hotkey")
    private var configuration: ShortcutConfiguration
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0
    private let maxTapRetries = 30
    private var shouldConsumeEscape = false

    private var triggerKeyIsDown = false
    private var triggerPressStartTime: TimeInterval = 0
    private var holdStarted = false
    private var pendingHoldStart: DispatchWorkItem?
    private var otherKeyPressedWhileDown = false
    private var waitingForSecondTap = false
    private var secondTapTimeoutWorkItem: DispatchWorkItem?

    init(configuration: ShortcutConfiguration) {
        self.configuration = configuration
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
        secondTapTimeoutWorkItem?.cancel()
        pendingHoldStart?.cancel()

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
        log.notice("shortcut updated key=\(configuration.triggerKey.rawValue) mode=\(configuration.mode.rawValue) doubleTap=\(configuration.doubleTapWindowMs)")
        self.configuration = configuration
        cancelTransientState()
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

        if waitingForSecondTap, keyCode != configuration.triggerKey.keyCode {
            waitingForSecondTap = false
            secondTapTimeoutWorkItem?.cancel()
            log.notice("double tap cancelled by keyCode=\(keyCode)")
        }

        if triggerKeyIsDown, keyCode != configuration.triggerKey.keyCode {
            otherKeyPressedWhileDown = true
        }

        return Unmanaged.passRetained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == configuration.triggerKey.keyCode else {
            return Unmanaged.passRetained(event)
        }

        let isDown = keyIsDown(for: configuration.triggerKey, flags: event.flags)
        let timestamp = ProcessInfo.processInfo.systemUptime

        if isDown {
            handleTriggerDown(at: timestamp)
        } else {
            handleTriggerUp(at: timestamp)
        }

        return Unmanaged.passRetained(event)
    }

    private func handleTriggerDown(at timestamp: TimeInterval) {
        guard !triggerKeyIsDown else { return }
        triggerKeyIsDown = true
        triggerPressStartTime = timestamp
        otherKeyPressedWhileDown = false
        log.notice("trigger down key=\(configuration.triggerKey.rawValue) mode=\(configuration.mode.rawValue)")

        switch configuration.mode {
        case .hold:
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.triggerKeyIsDown else { return }
                self.holdStarted = true
                self.onHotkeyEvent?(.startRecording)
            }
            pendingHoldStart = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
        case .singleTapToggle, .doubleTapToggle:
            break
        }
    }

    private func handleTriggerUp(at timestamp: TimeInterval) {
        guard triggerKeyIsDown else { return }
        triggerKeyIsDown = false
        pendingHoldStart?.cancel()
        pendingHoldStart = nil

        let pressDuration = timestamp - triggerPressStartTime
        log.notice("trigger up mode=\(configuration.mode.rawValue) duration=\(pressDuration) waitingSecondTap=\(waitingForSecondTap)")
        defer {
            holdStarted = false
        }

        switch configuration.mode {
        case .hold:
            if holdStarted {
                onHotkeyEvent?(.stopRecording)
            } else if pressDuration < 0.08 {
                log.notice("hold ignored as accidental press duration=\(pressDuration)")
            }
        case .singleTapToggle:
            guard !otherKeyPressedWhileDown else { return }
            onHotkeyEvent?(.toggleRecording)
        case .doubleTapToggle:
            guard !otherKeyPressedWhileDown else { return }
            if waitingForSecondTap {
                waitingForSecondTap = false
                secondTapTimeoutWorkItem?.cancel()
                secondTapTimeoutWorkItem = nil
                log.notice("double tap recognized")
                onHotkeyEvent?(.toggleRecording)
            } else {
                waitingForSecondTap = true
                log.notice("double tap armed window=\(configuration.doubleTapWindowMs)")
                let timeout = DispatchWorkItem { [weak self] in
                    self?.log.notice("double tap window expired")
                    self?.waitingForSecondTap = false
                }
                secondTapTimeoutWorkItem = timeout
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

    private func cancelTransientState() {
        triggerKeyIsDown = false
        holdStarted = false
        waitingForSecondTap = false
        otherKeyPressedWhileDown = false
        pendingHoldStart?.cancel()
        secondTapTimeoutWorkItem?.cancel()
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
