import Foundation

public enum ShortcutTriggerKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case rightOption
    case leftOption
    case rightCommand
    case leftCommand
    case rightControl
    case capsLock
    case function

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightOption:
            return "Right Option"
        case .leftOption:
            return "Left Option"
        case .rightCommand:
            return "Right Command"
        case .leftCommand:
            return "Left Command"
        case .rightControl:
            return "Right Control"
        case .capsLock:
            return "Caps Lock"
        case .function:
            return "Fn"
        }
    }

    public var supportsFlagsChanged: Bool { true }

    public var keyCode: Int64 {
        switch self {
        case .leftCommand:
            return 55
        case .rightCommand:
            return 54
        case .leftOption:
            return 58
        case .rightOption:
            return 61
        case .rightControl:
            return 62
        case .capsLock:
            return 57
        case .function:
            return 63
        }
    }
}

public enum ShortcutMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case hold
    case singleTapToggle
    case doubleTapToggle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none:
            return "无"
        case .hold:
            return "Hold"
        case .singleTapToggle:
            return "Single Tap Toggle"
        case .doubleTapToggle:
            return "Double Tap Toggle"
        }
    }
}

public enum ShortcutSlotIdentifier: String, CaseIterable, Codable, Sendable, Identifiable {
    case primary
    case secondary

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary:
            return "触发方式 1"
        case .secondary:
            return "触发方式 2"
        }
    }
}

public struct ShortcutTriggerSlot: Codable, Equatable, Sendable {
    public var triggerKey: ShortcutTriggerKey
    public var mode: ShortcutMode

    public init(
        triggerKey: ShortcutTriggerKey = .rightOption,
        mode: ShortcutMode = .none
    ) {
        self.triggerKey = triggerKey
        self.mode = mode
    }

    public var isEnabled: Bool {
        mode != .none
    }

    public var displaySummary: String {
        isEnabled ? "\(triggerKey.displayName) · \(mode.displayName)" : "无"
    }
}

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public static let minimumDoubleTapWindowMs = 150
    public static let maximumDoubleTapWindowMs = 500
    public static let defaultDoubleTapWindowMs = 200
    public static let previousDefaultDoubleTapWindowMs = 300

    public var primary: ShortcutTriggerSlot
    public var secondary: ShortcutTriggerSlot
    public var doubleTapWindowMs: Int

    public init(
        triggerKey: ShortcutTriggerKey = .rightOption,
        mode: ShortcutMode = .hold,
        doubleTapWindowMs: Int = ShortcutConfiguration.defaultDoubleTapWindowMs
    ) {
        self.primary = ShortcutTriggerSlot(triggerKey: triggerKey, mode: mode)
        self.secondary = ShortcutTriggerSlot(triggerKey: .rightCommand, mode: .none)
        self.doubleTapWindowMs = ShortcutConfiguration.clampDoubleTapWindowMs(doubleTapWindowMs)
    }

    public init(
        primary: ShortcutTriggerSlot,
        secondary: ShortcutTriggerSlot = ShortcutTriggerSlot(triggerKey: .rightCommand, mode: .none),
        doubleTapWindowMs: Int = ShortcutConfiguration.defaultDoubleTapWindowMs
    ) {
        self.primary = primary
        self.secondary = secondary
        self.doubleTapWindowMs = ShortcutConfiguration.clampDoubleTapWindowMs(doubleTapWindowMs)
    }

    public var triggerKey: ShortcutTriggerKey {
        get { primary.triggerKey }
        set { primary.triggerKey = newValue }
    }

    public var mode: ShortcutMode {
        get { primary.mode }
        set { primary.mode = newValue }
    }

    public var enabledSlots: [(ShortcutSlotIdentifier, ShortcutTriggerSlot)] {
        [
            (.primary, primary),
            (.secondary, secondary),
        ].filter { $0.1.isEnabled }
    }

    public var hasKeyConflict: Bool {
        false
    }

    public var usesDoubleTap: Bool {
        primary.mode == .doubleTapToggle || secondary.mode == .doubleTapToggle
    }

    public var displaySummary: String {
        let primaryText = "1: \(primary.displaySummary)"
        let secondaryText = "2: \(secondary.displaySummary)"
        return "\(primaryText) / \(secondaryText)"
    }

    public func normalizedForRuntime() -> ShortcutConfiguration {
        self
    }

    public static func clampDoubleTapWindowMs(_ value: Int) -> Int {
        min(max(value, minimumDoubleTapWindowMs), maximumDoubleTapWindowMs)
    }
}
