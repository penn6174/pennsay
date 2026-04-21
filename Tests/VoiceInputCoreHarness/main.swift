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
}
