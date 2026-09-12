import Foundation

// MARK: - Graph Edge

/// A typed connection between two node ports.
struct GraphEdge: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceNodeId: UUID
    let sourcePortId: String
    let targetNodeId: UUID
    let targetPortId: String
    let signalType: SignalType
    
    /// Phase 6: Metadata for cross-lane connections and other edge properties.
    /// Stored as [String: String] for Codable compatibility.
    var metadata: [String: String]
    
    init(
        id: UUID = UUID(),
        sourceNodeId: UUID,
        sourcePortId: String,
        targetNodeId: UUID,
        targetPortId: String,
        signalType: SignalType,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceNodeId = sourceNodeId
        self.sourcePortId = sourcePortId
        self.targetNodeId = targetNodeId
        self.targetPortId = targetPortId
        self.signalType = signalType
        self.metadata = metadata
    }
    
    /// Helper to access metadata as Bool
    var isCrossLane: Bool {
        metadata["isCrossLane"] == "true"
    }
    
    /// Helper to get source lane ID from metadata
    var sourceLaneId: UUID? {
        guard let uuidString = metadata["sourceLaneId"] else { return nil }
        return UUID(uuidString: uuidString)
    }
    
    /// Helper to get target lane ID from metadata
    var targetLaneId: UUID? {
        guard let uuidString = metadata["targetLaneId"] else { return nil }
        return UUID(uuidString: uuidString)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: GraphEdge, rhs: GraphEdge) -> Bool {
        lhs.id == rhs.id
    }

    // Custom Codable to handle missing metadata field
    private enum CodingKeys: String, CodingKey {
        case id, sourceNodeId, sourcePortId, targetNodeId, targetPortId, signalType, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceNodeId = try container.decode(UUID.self, forKey: .sourceNodeId)
        sourcePortId = try container.decode(String.self, forKey: .sourcePortId)
        targetNodeId = try container.decode(UUID.self, forKey: .targetNodeId)
        targetPortId = try container.decode(String.self, forKey: .targetPortId)
        signalType = try container.decode(SignalType.self, forKey: .signalType)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

// MARK: - Graph Mutation

/// Actions that modify the graph structure.
/// Used for undo/redo and bridge protocol messages.
enum GraphMutation {
    case addNode(id: UUID, nodeType: String, position: CGPoint, params: [String: Any])
    case removeNode(id: UUID)
    case connectEdge(edge: GraphEdge)
    case disconnectEdge(id: UUID)
    case setParameter(nodeId: UUID, paramId: String, value: Any)
    
    /// Returns true if this mutation requires rebuilding the audio graph.
    /// Parameter changes don't require rebuild (in-place update).
    /// Topology changes (add/remove/connect) require full rebuild.
    var requiresAudioGraphRebuild: Bool {
        switch self {
        case .setParameter:
            return false
        case .addNode, .removeNode, .connectEdge, .disconnectEdge:
            return true
        }
    }
}
