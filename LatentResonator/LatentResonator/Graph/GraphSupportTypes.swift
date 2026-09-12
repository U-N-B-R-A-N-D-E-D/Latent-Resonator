import Foundation

// MARK: - Exposed Control / Macro Binding / Graph Errors
//
// Extracted (behavior-preserving) from `NodeGraph.swift` as part of the
// P3.13 "NodeGraph.swift vertedero cleanup" refactor. These are plain
// top-level Codable value types and the `GraphError` enum, all consumed
// by `NodeGraph` and by PERFORM-view / macro-binding UI. They carry no
// `NodeGraph` private state and are referenced as bare module-scope
// type names, so lifting them into a sibling file changes neither the
// public API nor runtime behavior. Swift resolves the types at module
// scope across files in the same target.

// MARK: - Exposed Control

/// Metadata for a node parameter promoted to the PERFORM surface.
struct ExposedControl: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let paramId: String
    let label: String
    let controlType: ControlWidget
    let defaultValue: Float
    var midiCC: Int?
    var position: Int

    /// Internal Codable storage for the range.
    private var codableRange: CodableFloatRange

    /// Public accessor for the parameter range.
    var range: ClosedRange<Float> {
        get { codableRange.range }
        set { codableRange = newValue.codable }
    }

    /// Initialize with all properties.
    init(
        id: UUID = UUID(),
        nodeId: UUID,
        paramId: String,
        label: String,
        controlType: ControlWidget,
        range: ClosedRange<Float>,
        defaultValue: Float,
        midiCC: Int? = nil,
        position: Int
    ) {
        self.id = id
        self.nodeId = nodeId
        self.paramId = paramId
        self.label = label
        self.controlType = controlType
        self.codableRange = range.codable
        self.defaultValue = defaultValue
        self.midiCC = midiCC
        self.position = position
    }

    // MARK: - Backward-Compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, nodeId, paramId, label, controlType, defaultValue, midiCC, position
        case codableRange, range
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        nodeId = try container.decode(UUID.self, forKey: .nodeId)
        paramId = try container.decode(String.self, forKey: .paramId)
        label = try container.decode(String.self, forKey: .label)
        controlType = try container.decode(ControlWidget.self, forKey: .controlType)
        defaultValue = try container.decode(Float.self, forKey: .defaultValue)
        midiCC = try container.decodeIfPresent(Int.self, forKey: .midiCC)
        position = try container.decode(Int.self, forKey: .position)

        // Try new format first (codableRange)
        if let range = try? container.decode(CodableFloatRange.self, forKey: .codableRange) {
            codableRange = range
        } else if let rangeArray = try? container.decode([Float].self, forKey: .range),
                  rangeArray.count >= 2 {
            // Legacy format: range: [lower, upper]
            codableRange = CodableFloatRange(lowerBound: rangeArray[0], upperBound: rangeArray[1])
        } else {
            throw DecodingError.dataCorruptedError(forKey: .range, in: container, debugDescription: "Cannot decode range for ExposedControl")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encode(paramId, forKey: .paramId)
        try container.encode(label, forKey: .label)
        try container.encode(controlType, forKey: .controlType)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(midiCC, forKey: .midiCC)
        try container.encode(position, forKey: .position)
        try container.encode(codableRange, forKey: .codableRange)
    }
}

enum ControlWidget: String, Codable {
    case knob
    case fader
    case xyPad
    case toggle
    case dropdown
}

// MARK: - Macro Binding

/// Maps one exposed control to multiple node parameters with scaling.
struct MacroBinding: Codable, Identifiable {
    let id: UUID
    let exposedControlId: UUID
    let targets: [MacroTarget]
    
    init(id: UUID = UUID(), exposedControlId: UUID, targets: [MacroTarget]) {
        self.id = id
        self.exposedControlId = exposedControlId
        self.targets = targets
    }
}

struct MacroTarget: Codable {
    let nodeId: UUID
    let paramId: String
    let curve: ScalingCurve

    // Internal Codable storage for ranges
    private var codableInputRange: CodableFloatRange
    private var codableOutputRange: CodableFloatRange

    /// Input range for scaling.
    var inputRange: ClosedRange<Float> {
        get { codableInputRange.range }
        set { codableInputRange = newValue.codable }
    }

    /// Output range for scaling.
    var outputRange: ClosedRange<Float> {
        get { codableOutputRange.range }
        set { codableOutputRange = newValue.codable }
    }

    init(
        nodeId: UUID,
        paramId: String,
        inputRange: ClosedRange<Float>,
        outputRange: ClosedRange<Float>,
        curve: ScalingCurve
    ) {
        self.nodeId = nodeId
        self.paramId = paramId
        self.codableInputRange = inputRange.codable
        self.codableOutputRange = outputRange.codable
        self.curve = curve
    }

    // MARK: - Backward-Compatible Codable

    private enum CodingKeys: String, CodingKey {
        case nodeId, paramId, curve
        case codableInputRange, codableOutputRange
        // Legacy keys
        case inputLowerBound, inputUpperBound, outputLowerBound, outputUpperBound
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        nodeId = try container.decode(UUID.self, forKey: .nodeId)
        paramId = try container.decode(String.self, forKey: .paramId)
        curve = try container.decode(ScalingCurve.self, forKey: .curve)

        // Try new format first
        if let inRange = try? container.decode(CodableFloatRange.self, forKey: .codableInputRange),
           let outRange = try? container.decode(CodableFloatRange.self, forKey: .codableOutputRange) {
            codableInputRange = inRange
            codableOutputRange = outRange
        } else {
            // Fall back to legacy format
            let inLower = try container.decode(Float.self, forKey: .inputLowerBound)
            let inUpper = try container.decode(Float.self, forKey: .inputUpperBound)
            let outLower = try container.decode(Float.self, forKey: .outputLowerBound)
            let outUpper = try container.decode(Float.self, forKey: .outputUpperBound)
            codableInputRange = CodableFloatRange(lowerBound: inLower, upperBound: inUpper)
            codableOutputRange = CodableFloatRange(lowerBound: outLower, upperBound: outUpper)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encode(paramId, forKey: .paramId)
        try container.encode(curve, forKey: .curve)
        try container.encode(codableInputRange, forKey: .codableInputRange)
        try container.encode(codableOutputRange, forKey: .codableOutputRange)
    }
}

enum ScalingCurve: String, Codable {
    case linear
    case exponential
    case logarithmic
    case inverted
    case sCurve
}

// MARK: - Graph Errors

enum GraphError: Error, LocalizedError {
    case unknownNodeType(String)
    case invalidConnection(String)
    case nodeNotFound(UUID)
    case edgeNotFound(UUID)
    case cycleDetected(String)

    var errorDescription: String? {
        switch self {
        case .unknownNodeType(let type):
            return "Unknown node type: \(type)"
        case .invalidConnection(let reason):
            return "Invalid connection: \(reason)"
        case .nodeNotFound(let id):
            return "Node not found: \(id)"
        case .edgeNotFound(let id):
            return "Edge not found: \(id)"
        case .cycleDetected(let reason):
            return "Cycle detected: \(reason)"
        }
    }
}
