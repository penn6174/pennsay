import Foundation

public struct WaveformLevelProcessor: Sendable {
    public struct Configuration: Sendable {
        public var weights: [Double]
        public var attackFactor: Double
        public var releaseFactor: Double
        public var jitterAmount: Double
        public var minimumHeight: Double
        public var inputGain: Double

        public init(
            weights: [Double] = [0.5, 0.8, 1.0, 0.75, 0.55],
            attackFactor: Double = 0.4,
            releaseFactor: Double = 0.15,
            jitterAmount: Double = 0.04,
            minimumHeight: Double = 0.12,
            inputGain: Double = 5.5
        ) {
            self.weights = weights
            self.attackFactor = attackFactor
            self.releaseFactor = releaseFactor
            self.jitterAmount = jitterAmount
            self.minimumHeight = minimumHeight
            self.inputGain = inputGain
        }
    }

    private let configuration: Configuration
    private var currentLevels: [Double]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.currentLevels = Array(
            repeating: configuration.minimumHeight,
            count: configuration.weights.count
        )
    }

    public mutating func reset() {
        currentLevels = Array(
            repeating: configuration.minimumHeight,
            count: configuration.weights.count
        )
    }

    public mutating func process(
        rms: Double,
        randomValues: [Double]? = nil
    ) -> [Double] {
        let normalized = min(max(rms * configuration.inputGain, 0), 1)
        var nextLevels = currentLevels

        for index in configuration.weights.indices {
            let jitterUnit: Double
            if let randomValues, index < randomValues.count {
                jitterUnit = randomValues[index]
            } else {
                jitterUnit = Double.random(in: -1...1)
            }

            let jitter = jitterUnit * configuration.jitterAmount
            let target = min(
                max(configuration.minimumHeight, normalized * configuration.weights[index] + jitter),
                1
            )
            let current = currentLevels[index]
            let factor = target > current ? configuration.attackFactor : configuration.releaseFactor
            nextLevels[index] = current + (target - current) * factor
        }

        currentLevels = nextLevels
        return nextLevels
    }
}
