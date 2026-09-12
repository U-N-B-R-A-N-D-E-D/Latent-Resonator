import Foundation
import CoreGraphics

// MARK: - Serialization Types
//
// Extracted (behavior-preserving) from `NodeGraph.swift` as part of the
// P3.13 "NodeGraph.swift vertedero cleanup" refactor. These are plain
// top-level Codable value types (`SerializedGraph`, `SerializedNode`,
// `CodableValue`, `GraphViewport`) consumed by `NodeGraph.serialize()` /
// `NodeGraph.deserialize(_:)` and by `NodeGraphStore`. They carry no
// `NodeGraph` private state and are referenced by callers as bare
// module-scope type names, so lifting them into a sibling file changes
// neither the public API nor runtime behavior. Swift resolves the types
// at module scope across files in the same target.

struct SerializedGraph: Codable {
    let version: String
    let nodes: [SerializedNode]
    let edges: [GraphEdge]
    let exposedControls: [ExposedControl]
    let macroBindings: [MacroBinding]
    let viewport: GraphViewport
}

struct SerializedNode: Codable {
    let id: UUID
    let nodeType: String
    let displayName: String
    let parameters: [String: CodableValue]
    let position: CGPoint
    let stageKind: StageKind?

    init(from node: any GraphNode) {
        self.id = node.id
        self.nodeType = node.nodeType
        self.displayName = node.name
        self.stageKind = (node as? BaseGraphNode)?.stageKind

        // Convert parameters to Codable-compatible values
        var codableParams: [String: CodableValue] = [:]
        for (key, value) in node.parameters {
            if let v = value as? Float {
                codableParams[key] = .float(v)
            } else if let v = value as? Int {
                codableParams[key] = .int(v)
            } else if let v = value as? String {
                codableParams[key] = .string(v)
            } else if let v = value as? Bool {
                codableParams[key] = .bool(v)
            }
        }
        self.parameters = codableParams

        // Store actual node position
        self.position = CGPoint(x: node.x, y: node.y)
    }

    // MARK: - Backward-Compatible Codable
    //
    // Bundled topologies (e.g. kickstart-legacy.json) may ship with `"position": [x, y]` (array format),
    // but Swift 5.9+'s SDK `CGPoint: Codable` uses keyed form `{"x":..., "y":...}`.
    // Without this custom decoder the template fails to load silently and the
    // app falls through to the emergency graph. We accept either format on
    // decode and emit the object form on encode (matches SDK default).

    private enum CodingKeys: String, CodingKey {
        case id, nodeType, displayName, parameters, position, stageKind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.nodeType = try container.decode(String.self, forKey: .nodeType)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.parameters = try container.decode([String: CodableValue].self, forKey: .parameters)

        if let rawStage = try container.decodeIfPresent(String.self, forKey: .stageKind) {
            self.stageKind = StageKind.resolve(rawStage)
        } else {
            self.stageKind = nil
        }

        // Position: accept both [x, y] and {"x":..., "y":...}
        if var arr = try? container.nestedUnkeyedContainer(forKey: .position) {
            let x = try arr.decode(CGFloat.self)
            let y = try arr.decode(CGFloat.self)
            self.position = CGPoint(x: x, y: y)
        } else {
            self.position = try container.decode(CGPoint.self, forKey: .position)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(nodeType, forKey: .nodeType)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(position, forKey: .position)
        try container.encodeIfPresent(stageKind, forKey: .stageKind)
    }
}

/// Type-safe wrapper for parameter values in serialization.
enum CodableValue: Codable {
    case float(Float)
    case int(Int)
    case string(String)
    case bool(Bool)

    var anyValue: Any {
        switch self {
        case .float(let v): return v
        case .int(let v): return v
        case .string(let v): return v
        case .bool(let v): return v
        }
    }

    // Custom Codable implementation for simple JSON format: {"float": 65.41}
    private enum CodingKeys: String, CodingKey {
        case float, int, string, bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Float.self, forKey: .float) {
            self = .float(value)
        } else if let value = try? container.decode(Int.self, forKey: .int) {
            self = .int(value)
        } else if let value = try? container.decode(String.self, forKey: .string) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self, forKey: .bool) {
            self = .bool(value)
        } else {
            throw DecodingError.typeMismatch(CodableValue.self, DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected one of: float, int, string, bool"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .float(let v): try container.encode(v, forKey: .float)
        case .int(let v): try container.encode(v, forKey: .int)
        case .string(let v): try container.encode(v, forKey: .string)
        case .bool(let v): try container.encode(v, forKey: .bool)
        }
    }
}

struct GraphViewport: Codable {
    var x: Float = 0
    var y: Float = 0
    var zoom: Float = 1.0
}

// MARK: - Subgraph clipboard helpers

extension NodeGraph {
    /// Returns a serializable subgraph containing only the selected nodes and
    /// edges that run between them. Exposed controls and viewport are omitted
    /// because the clipboard only stores structure, not performance-surface state.
    func subgraph(for nodeIds: Set<UUID>) -> SerializedGraph {
        let selectedNodes = nodes.values
            .filter { nodeIds.contains($0.id) }
            .map { SerializedNode(from: $0) }
        let selectedEdges = edges.values.filter { edge in
            nodeIds.contains(edge.sourceNodeId) && nodeIds.contains(edge.targetNodeId)
        }
        return SerializedGraph(
            version: "2.0.0",
            nodes: selectedNodes,
            edges: selectedEdges,
            exposedControls: [],
            macroBindings: [],
            viewport: GraphViewport()
        )
    }

    /// Pastes a serialized subgraph with a positional offset, creating new UUIDs
    /// for every node and edge so the copy is independent of the source. Returns
    /// the IDs of the newly created nodes.
    @discardableResult
    func pasteSubgraph(_ subgraph: SerializedGraph, offset: CGPoint) -> [UUID] {
        var idMap: [UUID: UUID] = [:]

        for node in subgraph.nodes {
            let newId = UUID()
            idMap[node.id] = newId

            var params: [String: Any] = [:]
            for (key, value) in node.parameters {
                params[key] = value.anyValue
            }

            if var newNode = NodeFactory.createNode(
                id: newId,
                type: node.nodeType,
                params: params,
                bridge: aceBridge,
                audioInputBuffer: audioInputBuffer
            ) {
                newNode.x = node.position.x + Double(offset.x)
                newNode.y = node.position.y + Double(offset.y)
                nodes[newId] = newNode
            }
        }

        for edge in subgraph.edges {
            guard let newSource = idMap[edge.sourceNodeId],
                  let newTarget = idMap[edge.targetNodeId] else { continue }

            let newEdge = GraphEdge(
                id: UUID(),
                sourceNodeId: newSource,
                sourcePortId: edge.sourcePortId,
                targetNodeId: newTarget,
                targetPortId: edge.targetPortId,
                signalType: edge.signalType
            )
            edges[newEdge.id] = newEdge
        }

        objectWillChange.send()
        topologyDidChange.send()
        return Array(idMap.values)
    }
}
