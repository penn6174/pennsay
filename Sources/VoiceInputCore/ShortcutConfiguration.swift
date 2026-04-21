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
    case hold
    case singleTapToggle
    case doubleTapToggle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hold:
            return "Hold"
        case .singleTapToggle:
            return "Single Tap Toggle"
        case .doubleTapToggle:
            return "Double Tap Toggle"
        }
    }
}

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public static let minimumDoubleTapWindowMs = 150
    public static let maximumDoubleTapWindowMs = 500
    public static let defaultDoubleTapWindowMs = 300

    public var triggerKey: ShortcutTriggerKey
    public var mode: ShortcutMode
    public var doubleTapWindowMs: Int

    public init(
        triggerKey: ShortcutTriggerKey = .rightOption,
        mode: ShortcutMode = .hold,
        doubleTapWindowMs: Int = ShortcutConfiguration.defaultDoubleTapWindowMs
    ) {
        self.triggerKey = triggerKey
        self.mode = mode
        self.doubleTapWindowMs = ShortcutConfiguration.clampDoubleTapWindowMs(doubleTapWindowMs)
    }

    public static func clampDoubleTapWindowMs(_ value: Int) -> Int {
        min(max(value, minimumDoubleTapWindowMs), maximumDoubleTapWindowMs)
    }
}
