import Foundation
import SwiftUI
import AVFoundation
import os.log

// MARK: - Node Category

/// Categories for graph nodes - determines visual appearance and behavior.
enum NodeCategory: String, Codable, CaseIterable {
    case source        // Audio input sources (oscillators, audio input)
    case effect        // Audio effects (filters, delays, distortion)
    case control       // Control signals (LFOs, envelopes, sequencers)
    case analysis      // Audio analysis (pitch, level, spectral)
    case neural        // AI/ML processing (ACE inference)
    case routing       // Signal routing (mixers, splitters, crossfaders)
    case macro         // Collapsible sub-graphs (lanes)
    case output        // Final output nodes
    
    var color: Color {
        switch self {
        case .source: return Color(hex: "#FF6B35")  // Orange
        case .effect: return Color(hex: "#4ECDC4") // Teal
        case .control: return Color(hex: "#FFE66D") // Yellow
        case .analysis: return Color(hex: "#95E1D3") // Light teal
        case .neural: return Color(hex: "#C7CEEA")  // Purple
        case .routing: return Color(hex: "#88D8B0") // Green
        case .macro: return Color(hex: "#FF8B94")  // Pink
        case .output: return Color(hex: "#F7FFF7") // Off-white
        }
    }
    
    var icon: String {
        switch self {
        case .source: return "waveform"
        case .effect: return "slider.horizontal.3"
        case .control: return "gauge"
        case .analysis: return "chart.bar"
        case .neural: return "brain.head.profile"
        case .routing: return "arrow.triangle.branch"
        case .macro: return "rectangle.stack"
        case .output: return "speaker.wave.3"
        }
    }
}

// MARK: - Signal Type

/// Types of signals that can flow through node ports.
enum SignalType: String, Codable {
    case audio    // Audio-rate signals (44.1kHz+)
    case control  // Control-rate signals (~60Hz)
    case trigger  // One-shot triggers (note on, step advance)
    case gate     // Sustained gates (note hold, step active)
    
    var color: Color {
        switch self {
        case .audio: return .cyan
        case .control: return .orange
        case .trigger: return .red
        case .gate: return .green
        }
    }
}

// MARK: - Port Direction

/// Direction of data flow for a node port.
enum PortDirection: String, Codable {
    case input
    case output
}

// MARK: - Node Port

/// A connection point on a node.
struct NodePort: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var signalType: SignalType
    var direction: PortDirection
    
    /// Optional: current value for display (normalized 0..1)
    var currentValue: Float?
    
    init(id: String, label: String, signalType: SignalType, direction: PortDirection, currentValue: Float? = nil) {
        self.id = id
        self.label = label
        self.signalType = signalType
        self.direction = direction
        self.currentValue = currentValue
    }
}

// MARK: - Node Telemetry

/// Real-time telemetry data from a running node.
struct NodeTelemetry {
    /// Current audio level (RMS) in dB
    var rmsLevel: Float
    
    /// Spectral centroid (brightness) in Hz
    var spectralCentroid: Float
    
    /// Spectral flatness (noisiness vs tonality) 0..1
    var spectralFlatness: Float
    
    /// Current output level for UI meters 0..1
    var level: Float
    
    /// Whether this node is currently active (receiving/processing signal)
    var isActive: Bool
    
    /// CPU usage for this node (0..1, approximate)
    var cpuUsage: Float
    
    init(
        rmsLevel: Float = -96.0,
        spectralCentroid: Float = 1000.0,
        spectralFlatness: Float = 0.5,
        level: Float = 0.0,
        isActive: Bool = false,
        cpuUsage: Float = 0.0
    ) {
        self.rmsLevel = rmsLevel
        self.spectralCentroid = spectralCentroid
        self.spectralFlatness = spectralFlatness
        self.level = level
        self.isActive = isActive
        self.cpuUsage = cpuUsage
    }
}

// MARK: - Graph Node Protocol

/// Protocol defining the interface for all nodes in the graph.
protocol GraphNode: Identifiable, Codable {
    /// Unique identifier for this node instance.
    var id: UUID { get }
    
    /// The type identifier for this node class (e.g., "oscillator", "ladder_filter").
    var nodeType: String { get }
    
    /// Human-readable display name.
    var name: String { get set }
    
    /// Visual category for coloring and iconography.
    var category: NodeCategory { get }
    
    /// Position in the graph editor (PATCH view).
    var x: Double { get set }
    var y: Double { get set }
    
    /// Parameters stored as key-value pairs.
    /// Keys are parameter names, values are Float, Int, String, or Bool.
    var parameters: [String: Any] { get set }
    
    /// Input and output ports for connections.
    var ports: [NodePort] { get }
    
    /// Real-time telemetry data (updated by audio engine).
    var telemetry: NodeTelemetry { get }
    
    /// Optional: Returns an AVAudioNode for direct AudioUnit integration.
    /// Returns nil for nodes that don't have direct AudioUnit equivalents.
    func audioUnit() -> AVAudioNode?
    
    /// Called when a parameter value changes.
    /// Override to update internal state or AudioUnit parameters.
    mutating func onParameterChanged(key: String, value: Any)
    
    /// Get parameter as Float with default.
    func getParam<T>(_ key: String, default defaultValue: T) -> T
    
    /// Set parameter value.
    mutating func setParam<T>(_ key: String, value: T)
}

// MARK: - Base Graph Node

/// Base class providing common functionality for all graph nodes.
/// Subclasses should override `ports`, `category`, and `audioUnit()` as needed.
class BaseGraphNode: GraphNode, ObservableObject {
    let id: UUID
    let nodeType: String
    var name: String

    /// Stored backing for the node's category. The public getter is read-only
    /// so subclasses can override it with a computed property if they wish.
    private var _category: NodeCategory
    var category: NodeCategory { _category }

    var x: Double = 0
    var y: Double = 0

    /// Conceptual stage role (Seed, Resonator, Spectra, …). Persisted via `SerializedNode`.
    var stageKind: StageKind?

    /// Node parameters - observable so UI updates when parameters change.
    @Published var parameters: [String: Any] = [:]
    
    /// Override this in subclasses to define ports.
    var ports: [NodePort] { [] }
    
    /// Override this in subclasses to provide telemetry.
    var telemetry: NodeTelemetry { NodeTelemetry() }
    
    /// Convenience initializer.
    init(
        id: UUID = UUID(),
        nodeType: String = "base",
        name: String? = nil,
        category: NodeCategory = .source,
        displayName: String? = nil,
        x: Double = 0,
        y: Double = 0,
        parameters: [String: Any] = [:]
    ) {
        self.id = id
        self.nodeType = nodeType
        self.name = displayName ?? name ?? "Node"
        self._category = category
        self.x = x
        self.y = y
        self.parameters = parameters
        self.stageKind = nil
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nodeType = try container.decode(String.self, forKey: .nodeType)
        name = try container.decode(String.self, forKey: .name)
        let categoryRaw = try container.decodeIfPresent(String.self, forKey: .category) ?? NodeCategory.source.rawValue
        _category = NodeCategory(rawValue: categoryRaw) ?? .source
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        stageKind = try container.decodeIfPresent(StageKind.self, forKey: .stageKind)

        // Decode parameters using NodeGraph's CodableValue
        let paramContainer = try container.decode([String: CodableValue].self, forKey: .parameters)
        parameters = paramContainer.mapValues { $0.anyValue }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeType, forKey: .nodeType)
        try container.encode(name, forKey: .name)
        try container.encode(category.rawValue, forKey: .category)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encodeIfPresent(stageKind, forKey: .stageKind)

        // Encode parameters using CodableValue
        let paramContainer = parameters.compactMapValues { param -> CodableValue? in
            if let f = param as? Float { return .float(f) }
            if let i = param as? Int { return .int(i) }
            if let s = param as? String { return .string(s) }
            if let b = param as? Bool { return .bool(b) }
            return nil
        }
        try container.encode(paramContainer, forKey: .parameters)
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, nodeType, name, x, y, parameters, category, stageKind
    }
    
    // MARK: - Parameter Access
    
    func getParam<T>(_ key: String, default defaultValue: T) -> T {
        guard let value = parameters[key] else { return defaultValue }
        
        // Type coercion for common cases
        if let typedValue = value as? T {
            return typedValue
        }
        
        // Float/Double coercion
        if T.self == Float.self, let doubleValue = value as? Double {
            return Float(doubleValue) as! T
        }
        if T.self == Double.self, let floatValue = value as? Float {
            return Double(floatValue) as! T
        }
        
        // Int/Float coercion
        if T.self == Float.self, let intValue = value as? Int {
            return Float(intValue) as! T
        }
        if T.self == Int.self, let floatValue = value as? Float {
            return Int(floatValue) as! T
        }

        // Type-mismatch fallthrough: surface the silent failure.
        // `value` exists for `key` but no coercion path applied. Without this
        // diagnostic getParam would silently return `defaultValue`, hiding
        // real bugs (e.g. a String stored where a Float was expected).
        Self.logParamTypeMismatch(
            key: key,
            actual: String(describing: type(of: value)),
            expected: String(describing: T.self)
        )

        return defaultValue
    }

    /// Constrained overload: when `T` is a `String`-rawvalue enum, restore
    /// it transparently from the serialized rawValue. Topologies (JSON) and
    /// cross-node parameter writes (e.g. `ControlNodes.swift`) store enums
    /// as their String rawValue; without this path, `getParam` would fall
    /// through to the type-mismatch diagnostic and crash DEBUG builds.
    func getParam<T: RawRepresentable>(_ key: String, default defaultValue: T) -> T where T.RawValue == String {
        guard let value = parameters[key] else { return defaultValue }
        if let typed = value as? T { return typed }
        if let raw = value as? String, let converted = T(rawValue: raw) { return converted }
        return defaultValue
    }

    // MARK: - Parameter Type-Mismatch Diagnostics

    /// Rate-limits release-mode `os_log` warnings to one per (key, actualType, expectedType)
    /// triple. The miss path is cold (a real bug, not a hot loop), so the set stays tiny.
    /// In DEBUG, every mismatch is logged via `os_log` without terminating the process;
    /// tests intentionally exercise the fallback-return path.
    private static let _warnedMismatchesLock = NSLock()
    private static var _warnedMismatches = Set<String>()

    private static func logParamTypeMismatch(key: String, actual: String, expected: String) {
        #if DEBUG
        // Log every mismatch in DEBUG without crashing the process. Tests exercise
        // the fallback-return path intentionally; a fatal assert would prevent that
        // verification while adding no runtime value beyond the log itself.
        os_log(.error,
               "getParam type mismatch: %{public}@ has %{public}@, expected %{public}@",
               key, actual, expected)
        #else
        let token = "\(key)::\(actual)::\(expected)"
        _warnedMismatchesLock.lock()
        let inserted = _warnedMismatches.insert(token).inserted
        _warnedMismatchesLock.unlock()
        if inserted {
            os_log(.error,
                   "getParam type mismatch: %{public}@ has %{public}@, expected %{public}@",
                   key, actual, expected)
        }
        #endif
    }
    
    func setParam<T>(_ key: String, value: T) {
        parameters[key] = value
        onParameterChanged(key: key, value: value)
    }
    
    // MARK: - Overrides
    
    func audioUnit() -> AVAudioNode? { nil }
    
    func onParameterChanged(key: String, value: Any) {
        // Default: no-op. Subclasses override to update AudioUnits.
    }
}

// MARK: - Stage Identity (Envion-style canvas headers)

extension GraphNode {
    /// Explicit `stageKind` from topology JSON, else inferred from `nodeType`.
    var effectiveStageKind: StageKind? {
        if let base = self as? BaseGraphNode, let kind = base.stageKind {
            return kind
        }
        if let macro = self as? MacroNode,
           let raw = macro.internalGraph.metadata["stageKind"],
           let kind = StageKind.resolve(raw) {
            return kind
        }
        return StageKind.inferred(for: self)
    }

    /// Resonator / feedback-loop cards get hero emphasis on the canvas.
    var isResonatorHero: Bool {
        effectiveStageKind == .resonator || nodeType == "feedback_loop"
    }
}

// MARK: - Color Helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
