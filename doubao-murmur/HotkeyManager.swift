import Cocoa

final class HotkeyManager {
    enum HotkeyEvent {
        case startRecording
        case stopRecording
        case toggleRecording
        case cancel
    }

    private final class RuntimeKey {
        let triggerKey: ShortcutTriggerKey
        private let supportedModes: Set<ShortcutMode>
        var triggerKeyIsDown = false
        var triggerPressStartTime: TimeInterval = 0
        var holdStarted = false
        var holdCommitted = false
        var pendingHoldCommit: DispatchWorkItem?
        var otherKeyPressedWhileDown = false
        var waitingForSecondTap = false
        var secondTapTimeoutWorkItem: DispatchWorkItem?

        init(triggerKey: ShortcutTriggerKey, supportedModes: Set<ShortcutMode>) {
            self.triggerKey = triggerKey
            self.supportedModes = supportedModes
        }

        var supportsHold: Bool {
            supportedModes.contains(.hold)
        }

        var supportsSingleTap: Bool {
            supportedModes.contains(.singleTapToggle)
        }

        var supportsDoubleTap: Bool {
            supportedModes.contains(.doubleTapToggle)
        }

        var requiresHoldDelay: Bool {
            supportsHold && (supportsSingleTap || supportsDoubleTap)
        }

        var modeSummary: String {
            [
                ShortcutMode.hold,
                .singleTapToggle,
                .doubleTapToggle,
            ]
            .filter { supportedModes.contains($0) }
            .map(\.rawValue)
            .joined(separator: "+")
        }

        func cancelTransientState() {
            triggerKeyIsDown = false
            holdStarted = false
            holdCommitted = false
            waitingForSecondTap = false
            otherKeyPressedWhileDown = false
            pendingHoldCommit?.cancel()
            pendingHoldCommit = nil
            secondTapTimeoutWorkItem?.cancel()
            secondTapTimeoutWorkItem = nil
        }
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
    var isRecordingSessionActive: (() -> Bool)?

    private let log = AppLog(category: "Hotkey")
    private var configuration: ShortcutConfiguration
    private var runtimeKeys: [RuntimeKey] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0
    private let maxTapRetries = 30
    private var shouldConsumeEscape = false
    private let sharedHoldCommitDelay: TimeInterval = 0.18
    private let accidentalHoldPressThreshold: TimeInterval = 0.08

    init(configuration: ShortcutConfiguration) {
        self.configuration = configuration.normalizedForRuntime()
        rebuildRuntimeKeys()
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
        rebuildRuntimeKeys()
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

        for runtimeKey in runtimeKeys {
            if runtimeKey.waitingForSecondTap, keyCode != runtimeKey.triggerKey.keyCode {
                cancelTapSequence(for: runtimeKey, reason: "keyDown=\(keyCode)")
            }

            if runtimeKey.triggerKeyIsDown, keyCode != runtimeKey.triggerKey.keyCode {
                runtimeKey.otherKeyPressedWhileDown = true
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        for runtimeKey in runtimeKeys where runtimeKey.triggerKeyIsDown && runtimeKey.triggerKey.keyCode != keyCode {
            runtimeKey.otherKeyPressedWhileDown = true
        }

        guard let runtimeKey = runtimeKeys.first(where: { $0.triggerKey.keyCode == keyCode }) else {
            return Unmanaged.passRetained(event)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        let isDown = keyIsDown(for: runtimeKey.triggerKey, flags: event.flags)
        if isDown {
            handleTriggerDown(runtimeKey, at: timestamp)
        } else {
            handleTriggerUp(runtimeKey, at: timestamp)
        }

        return Unmanaged.passRetained(event)
    }

    private func handleTriggerDown(_ runtimeKey: RuntimeKey, at timestamp: TimeInterval) {
        guard !runtimeKey.triggerKeyIsDown else { return }
        runtimeKey.triggerKeyIsDown = true
        runtimeKey.triggerPressStartTime = timestamp
        runtimeKey.otherKeyPressedWhileDown = false
        log.notice("trigger down key=\(runtimeKey.triggerKey.rawValue) modes=\(runtimeKey.modeSummary) waitingSecondTap=\(runtimeKey.waitingForSecondTap)")

        if runtimeKey.waitingForSecondTap {
            runtimeKey.secondTapTimeoutWorkItem?.cancel()
            runtimeKey.secondTapTimeoutWorkItem = nil
        }

        guard runtimeKey.supportsHold else { return }
        let sessionActive = isRecordingSessionActive?() ?? false
        if runtimeKey.requiresHoldDelay {
            guard !sessionActive else { return }
            startHold(for: runtimeKey, committed: false)
            scheduleSharedHoldCommit(for: runtimeKey)
        } else {
            guard !sessionActive else { return }
            startHold(for: runtimeKey, committed: true)
        }
    }

    private func handleTriggerUp(_ runtimeKey: RuntimeKey, at timestamp: TimeInterval) {
        guard runtimeKey.triggerKeyIsDown else { return }
        runtimeKey.triggerKeyIsDown = false
        runtimeKey.pendingHoldCommit?.cancel()
        runtimeKey.pendingHoldCommit = nil

        let pressDuration = timestamp - runtimeKey.triggerPressStartTime
        log.notice("trigger up key=\(runtimeKey.triggerKey.rawValue) modes=\(runtimeKey.modeSummary) duration=\(pressDuration) holdStarted=\(runtimeKey.holdStarted) holdCommitted=\(runtimeKey.holdCommitted) waitingSecondTap=\(runtimeKey.waitingForSecondTap)")
        defer {
            runtimeKey.holdStarted = false
            runtimeKey.holdCommitted = false
            runtimeKey.otherKeyPressedWhileDown = false
        }

        if runtimeKey.holdStarted {
            if !runtimeKey.holdCommitted {
                log.notice("shared hold reverted to tap key=\(runtimeKey.triggerKey.rawValue) duration=\(pressDuration)")
                onHotkeyEvent?(.cancel)
                guard !runtimeKey.otherKeyPressedWhileDown else {
                    cancelTapSequence(for: runtimeKey, reason: "chord")
                    return
                }
                handleTapGesture(for: runtimeKey)
                return
            }

            if !runtimeKey.requiresHoldDelay, pressDuration < accidentalHoldPressThreshold {
                log.notice("hold cancelled as accidental press key=\(runtimeKey.triggerKey.rawValue) duration=\(pressDuration)")
                onHotkeyEvent?(.cancel)
            } else {
                onHotkeyEvent?(.stopRecording)
            }
            return
        }

        guard !runtimeKey.otherKeyPressedWhileDown else {
            cancelTapSequence(for: runtimeKey, reason: "chord")
            return
        }

        handleTapGesture(for: runtimeKey)

        if pressDuration < accidentalHoldPressThreshold {
            log.notice("hold ignored as accidental press key=\(runtimeKey.triggerKey.rawValue) duration=\(pressDuration)")
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

    private func scheduleSharedHoldCommit(for runtimeKey: RuntimeKey) {
        runtimeKey.pendingHoldCommit?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak runtimeKey] in
            guard let self, let runtimeKey else { return }
            guard runtimeKey.triggerKeyIsDown, runtimeKey.holdStarted, !runtimeKey.holdCommitted, !runtimeKey.otherKeyPressedWhileDown else {
                return
            }
            self.commitSharedHold(for: runtimeKey)
        }
        runtimeKey.pendingHoldCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + sharedHoldCommitDelay, execute: workItem)
    }

    private func startHold(for runtimeKey: RuntimeKey, committed: Bool) {
        guard !runtimeKey.holdStarted else {
            if committed {
                commitSharedHold(for: runtimeKey)
            }
            return
        }

        runtimeKey.holdStarted = true
        runtimeKey.holdCommitted = committed
        if committed {
            runtimeKey.waitingForSecondTap = false
            runtimeKey.secondTapTimeoutWorkItem?.cancel()
            runtimeKey.secondTapTimeoutWorkItem = nil
        }
        log.notice("hold started key=\(runtimeKey.triggerKey.rawValue) modes=\(runtimeKey.modeSummary) committed=\(committed)")
        onHotkeyEvent?(.startRecording)
    }

    private func commitSharedHold(for runtimeKey: RuntimeKey) {
        runtimeKey.pendingHoldCommit?.cancel()
        runtimeKey.pendingHoldCommit = nil
        guard runtimeKey.holdStarted, !runtimeKey.holdCommitted else { return }
        runtimeKey.holdCommitted = true
        runtimeKey.waitingForSecondTap = false
        runtimeKey.secondTapTimeoutWorkItem?.cancel()
        runtimeKey.secondTapTimeoutWorkItem = nil
        log.notice("shared hold committed key=\(runtimeKey.triggerKey.rawValue) modes=\(runtimeKey.modeSummary)")
    }

    private func handleTapGesture(for runtimeKey: RuntimeKey) {
        if runtimeKey.supportsDoubleTap {
            if runtimeKey.waitingForSecondTap {
                runtimeKey.waitingForSecondTap = false
                runtimeKey.secondTapTimeoutWorkItem?.cancel()
                runtimeKey.secondTapTimeoutWorkItem = nil
                log.notice("double tap recognized key=\(runtimeKey.triggerKey.rawValue)")
                onHotkeyEvent?(.toggleRecording)
            } else {
                armTapSequence(for: runtimeKey)
            }
            return
        }

        if runtimeKey.supportsSingleTap {
            log.notice("single tap recognized key=\(runtimeKey.triggerKey.rawValue)")
            onHotkeyEvent?(.toggleRecording)
        }
    }

    private func armTapSequence(for runtimeKey: RuntimeKey) {
        runtimeKey.waitingForSecondTap = true
        log.notice("double tap armed key=\(runtimeKey.triggerKey.rawValue) window=\(configuration.doubleTapWindowMs)")
        let timeout = DispatchWorkItem { [weak self, weak runtimeKey] in
            guard let self, let runtimeKey else { return }
            guard runtimeKey.waitingForSecondTap, !runtimeKey.triggerKeyIsDown else { return }
            self.log.notice("double tap window expired key=\(runtimeKey.triggerKey.rawValue)")
            runtimeKey.waitingForSecondTap = false
            runtimeKey.secondTapTimeoutWorkItem = nil
            guard runtimeKey.supportsSingleTap else { return }
            self.log.notice("single tap recognized after double tap window key=\(runtimeKey.triggerKey.rawValue)")
            self.onHotkeyEvent?(.toggleRecording)
        }
        runtimeKey.secondTapTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(configuration.doubleTapWindowMs),
            execute: timeout
        )
    }

    private func cancelTapSequence(for runtimeKey: RuntimeKey, reason: String) {
        guard runtimeKey.waitingForSecondTap || runtimeKey.secondTapTimeoutWorkItem != nil else { return }
        runtimeKey.waitingForSecondTap = false
        runtimeKey.secondTapTimeoutWorkItem?.cancel()
        runtimeKey.secondTapTimeoutWorkItem = nil
        log.notice("tap sequence cancelled key=\(runtimeKey.triggerKey.rawValue) reason=\(reason)")
    }

    private func rebuildRuntimeKeys() {
        cancelTransientState()
        var orderedKeys: [ShortcutTriggerKey] = []
        var groupedModes: [ShortcutTriggerKey: Set<ShortcutMode>] = [:]
        for (_, shortcut) in configuration.enabledSlots {
            if groupedModes[shortcut.triggerKey] == nil {
                orderedKeys.append(shortcut.triggerKey)
            }
            groupedModes[shortcut.triggerKey, default: []].insert(shortcut.mode)
        }
        runtimeKeys = orderedKeys.map { triggerKey in
            RuntimeKey(triggerKey: triggerKey, supportedModes: groupedModes[triggerKey] ?? [])
        }
    }

    private func cancelTransientState() {
        runtimeKeys.forEach { $0.cancelTransientState() }
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
