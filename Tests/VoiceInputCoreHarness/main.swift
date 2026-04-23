import Foundation
import VoiceInputCore

struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws -> Bool {
    guard condition() else {
        throw HarnessFailure(description: description)
    }
    print("PASS \(description)")
    return true
}

@main
struct VoiceInputCoreTestHarness {
    static func main() throws {
        try louderRMSProducesTallerBars()
        try releaseShrinksBarsWhenRMSFalls()
        try valuesStayWithinBounds()
        try shortcutDefaultHasOneEnabledSlot()
        try shortcutNoneSlotDoesNotEnable()
        try shortcutSameKeyDualModesRemainEnabled()
        try shortcutDoubleTapDetectionLooksAcrossBothSlots()
    }

    private static func louderRMSProducesTallerBars() throws {
        var processor = WaveformLevelProcessor(
            configuration: .init(jitterAmount: 0, minimumHeight: 0.1, inputGain: 6)
        )

        let quiet = processor.process(rms: 0.005, randomValues: [0, 0, 0, 0, 0])
        let loud = processor.process(rms: 0.08, randomValues: [0, 0, 0, 0, 0])

        try expect(loud[2] > quiet[2], "louder RMS produces taller center bar")
        try expect((loud.max() ?? 0) > (quiet.max() ?? 0), "louder RMS increases overall height")
    }

    private static func releaseShrinksBarsWhenRMSFalls() throws {
        var processor = WaveformLevelProcessor(
            configuration: .init(jitterAmount: 0, minimumHeight: 0.1, inputGain: 8)
        )

        _ = processor.process(rms: 0.10, randomValues: [0, 0, 0, 0, 0])
        let falling = processor.process(rms: 0.0, randomValues: [0, 0, 0, 0, 0])

        try expect(falling.allSatisfy { $0 >= 0.1 }, "release keeps bars above minimum height")
        try expect((falling.max() ?? 0) < 0.45, "release shrinks bars after silence")
    }

    private static func valuesStayWithinBounds() throws {
        var processor = WaveformLevelProcessor(
            configuration: .init(jitterAmount: 0.04, minimumHeight: 0.1, inputGain: 50)
        )
        let values = processor.process(rms: 1.0, randomValues: [1, 1, 1, 1, 1])
        try expect(values.allSatisfy { $0 >= 0.1 && $0 <= 1.0 }, "waveform heights stay within bounds")
    }

    private static func shortcutDefaultHasOneEnabledSlot() throws {
        let config = ShortcutConfiguration()
        try expect(config.primary.isEnabled, "default primary shortcut is enabled")
        try expect(!config.secondary.isEnabled, "default secondary shortcut is disabled")
        try expect(config.enabledSlots.count == 1, "default exposes one enabled runtime slot")
    }

    private static func shortcutNoneSlotDoesNotEnable() throws {
        let slot = ShortcutTriggerSlot(triggerKey: .rightCommand, mode: .none)
        try expect(!slot.isEnabled, "none mode disables a shortcut slot")
        try expect(slot.displaySummary == "无", "none mode displays as Chinese none label")
    }

    private static func shortcutSameKeyDualModesRemainEnabled() throws {
        let config = ShortcutConfiguration(
            primary: ShortcutTriggerSlot(triggerKey: .rightCommand, mode: .hold),
            secondary: ShortcutTriggerSlot(triggerKey: .rightCommand, mode: .doubleTapToggle)
        )
        try expect(!config.hasKeyConflict, "same key in both enabled slots is allowed")
        let normalized = config.normalizedForRuntime()
        try expect(normalized.primary.isEnabled, "same-key runtime keeps primary slot enabled")
        try expect(normalized.secondary.isEnabled, "same-key runtime keeps secondary slot enabled")
        try expect(normalized.enabledSlots.count == 2, "same-key dual-mode configuration exposes both enabled slots")
    }

    private static func shortcutDoubleTapDetectionLooksAcrossBothSlots() throws {
        let config = ShortcutConfiguration(
            primary: ShortcutTriggerSlot(triggerKey: .rightCommand, mode: .hold),
            secondary: ShortcutTriggerSlot(triggerKey: .rightOption, mode: .doubleTapToggle)
        )
        try expect(config.usesDoubleTap, "double tap slider enables when secondary slot uses double tap")
        try expect(config.enabledSlots.count == 2, "two non-conflicting slots are both enabled")
    }
}
