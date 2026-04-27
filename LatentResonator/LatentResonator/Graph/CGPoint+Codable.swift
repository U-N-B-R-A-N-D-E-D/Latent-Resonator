import Foundation
import CoreGraphics

// MARK: - CGPoint Codable Conformance

/// Extends CGPoint to support Codable serialization with array format.
/// Format: [x, y] for simplicity in JSON.
/// Note: Only defined when not already provided by the SDK.
#if swift(<5.9)
extension CGPoint: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(CGFloat.self)
        let y = try container.decode(CGFloat.self)
        self.init(x: x, y: y)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}
#endif

// MARK: - CodableFloatRange

/// A Codable wrapper for ClosedRange<Float> that serializes to/from JSON.
///
/// ClosedRange<Float> cannot conform to Codable directly because it uses @_nonSendable
/// and has complex generic constraints. This wrapper provides a clean serialization
/// format: {"lowerBound": 0.0, "upperBound": 1.0}
///
/// Usage:
///   - Store: `myRange.codable` to get CodableFloatRange
///   - Retrieve: `codableRange.range` to get ClosedRange<Float>
///   - Direct: Use `ClosedRange<Float>.codable` property
///
/// Whitepaper alignment: Parameter ranges are essential for the macro node
/// architecture (§4.2.1 CFG ranges, §5.4 filter ranges).
struct CodableFloatRange: Codable, Equatable {
    let lowerBound: Float
    let upperBound: Float

    /// Initialize with explicit bounds.
    init(lowerBound: Float, upperBound: Float) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Initialize from a ClosedRange<Float>.
    init(_ range: ClosedRange<Float>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }

    /// Get the underlying ClosedRange<Float>.
    var range: ClosedRange<Float> {
        lowerBound...upperBound
    }

    /// Check if a value is within the range.
    func contains(_ value: Float) -> Bool {
        range.contains(value)
    }

    /// Clamp a value to this range.
    func clamp(_ value: Float) -> Float {
        min(max(value, lowerBound), upperBound)
    }
}

// MARK: - ClosedRange<Float> Convenience

extension ClosedRange<Float> {
    /// Get a Codable wrapper for this range.
    var codable: CodableFloatRange {
        CodableFloatRange(self)
    }
}

// MARK: - CodableIntRange

/// A Codable wrapper for ClosedRange<Int>.
/// Format: {"lowerBound": 0, "upperBound": 100}
struct CodableIntRange: Codable, Equatable {
    let lowerBound: Int
    let upperBound: Int

    init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    init(_ range: ClosedRange<Int>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }

    var range: ClosedRange<Int> {
        lowerBound...upperBound
    }

    func contains(_ value: Int) -> Bool {
        range.contains(value)
    }
}

extension ClosedRange<Int> {
    var codable: CodableIntRange {
        CodableIntRange(self)
    }
}
