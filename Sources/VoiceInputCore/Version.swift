import Foundation

public struct Version: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init(_ rawValue: String) {
        components = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}
