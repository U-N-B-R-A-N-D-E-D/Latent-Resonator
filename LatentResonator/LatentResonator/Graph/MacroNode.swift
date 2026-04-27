import Foundation
import SwiftUI
import Combine
import AVFoundation

// MARK: - Macro Node

/// A macro-node encapsulates a subgraph into a single collapsible node.
/// Double-click to expand/collapse. Exposed ports on the boundary allow
/// external connections to internal nodes.
///
/// v2.0: MacroNode is now a standalone graph abstraction with no lane dependency.
/// The internalGraph contains the complete audio processing chain.
final class MacroNode: BaseGraphNode {

    // MARK: - Internal Graph
    
    /// The internal node graph contained within this macro.
    var internalGraph: NodeGraph
    
    /// Port mapping: external port ID → internal (nodeId, portId).
    /// When a signal enters the macro's input port, it's routed to the
    /// corresponding internal node's port.
    var portMappings: [String: (nodeId: UUID, portId: String)] = [:]
    
    // MARK: - Expansion State
    
    /// When true, the internal graph is visible in the PATCH view.
    /// When false, only the macro's external ports are shown.
    @Published var isExpanded: Bool = false
    
    init(
        id: UUID = UUID(),
        name: String,
        internalGraph: NodeGraph,
        exposedPorts: [NodePort],
        portMappings: [String: (nodeId: UUID, portId: String)]
    ) {
        self.internalGraph = internalGraph
        self.portMappings = portMappings
        self._ports = exposedPorts
        
        super.init(
            id: id,
            nodeType: "macro",
            category: .routing,
            displayName: name
        )
    }
    
    /// Convenience init for deserialization from saved params.
    /// Attempts to reconstruct from preset name if available.
    convenience init(id: UUID, params: [String: Any]) {
        // Try to reconstruct from preset name
        if let presetName = params["presetName"] as? String,
           let preset = LanePreset.allPresets.first(where: { $0.name == presetName }) {
            let tempMacro = MacroNode.fromPreset(preset: preset)
            self.init(
                id: id,
                name: preset.name,
                internalGraph: tempMacro.internalGraph,
                exposedPorts: tempMacro._ports,
                portMappings: tempMacro.portMappings
            )
        } else {
            // Fallback: create empty macro
            self.init(
                id: id,
                name: params["name"] as? String ?? "MACRO",
                internalGraph: NodeGraph(),
                exposedPorts: [],
                portMappings: [:]
            )
        }
    }
    
    // MARK: - Ports
    
    private var _ports: [NodePort]
    
    override var ports: [NodePort] {
        _ports
    }
    
    // MARK: - Audio Processing

    /// v2.0: MacroNode is a logical grouping, not a direct audio source.
    /// The internalGraph nodes provide the actual audio processing.
    /// Audio flows through the internal graph nodes, not through the MacroNode itself.
    override func audioUnit() -> AVAudioNode? {
        // MacroNode is a container - audio flows through its internalGraph nodes
        return nil
    }
    
    // MARK: - Expansion
    
    /// Toggle expanded/collapsed state.
    func toggleExpansion() {
        isExpanded.toggle()
    }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Initialize empty internal graph - will be populated by NodeGraphStore
        self.internalGraph = NodeGraph()
        
        // Decode ports and mappings
        self._ports = try container.decode([NodePort].self, forKey: .exposedPorts)
        let mappingDict = try container.decode([String: PortMappingEntry].self, forKey: .portMappings)
        self.portMappings = mappingDict.mapValues { (nodeId: $0.nodeId, portId: $0.portId) }
        self.isExpanded = try container.decode(Bool.self, forKey: .isExpanded)
        
        // Call super init
        try super.init(from: decoder)
    }
    
    override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Note: internalGraph serialization is handled by NodeGraphStore separately
        // We only encode macro-specific state here
        
        // Encode ports and mappings
        try container.encode(_ports, forKey: .exposedPorts)
        let mappingDict = portMappings.mapValues { PortMappingEntry(nodeId: $0.nodeId, portId: $0.portId) }
        try container.encode(mappingDict, forKey: .portMappings)
        try container.encode(isExpanded, forKey: .isExpanded)
        
        // Call super encode
        try super.encode(to: encoder)
    }
    
    private enum CodingKeys: String, CodingKey {
        case exposedPorts, portMappings, isExpanded
    }
    
    /// Helper struct for encoding/decoding port mappings
    private struct PortMappingEntry: Codable {
        let nodeId: UUID
        let portId: String
    }
}

// MARK: - NodeGraph Extension: Encapsulation

extension NodeGraph {
    
    /// Encapsulate a set of nodes into a macro-node.
    /// - Parameters:
    ///   - nodeIds: The set of node IDs to encapsulate.
    ///   - name: The name for the new macro-node.
    /// - Returns: The newly created MacroNode.
    /// - Throws: GraphError if validation fails.
    func encapsulate(nodeIds: Set<UUID>, name: String) throws -> MacroNode {
        // 1. Validate: all nodes exist
        for nodeId in nodeIds {
            guard nodes[nodeId] != nil else {
                throw GraphError.nodeNotFound(nodeId)
            }
        }
        
        // 2. Find boundary edges (edges crossing the selection boundary)
        var boundaryEdges: [GraphEdge] = []
        var internalEdges: [GraphEdge] = []
        
        for edge in edges.values {
            let sourceInSelection = nodeIds.contains(edge.sourceNodeId)
            let targetInSelection = nodeIds.contains(edge.targetNodeId)
            
            if sourceInSelection && targetInSelection {
                internalEdges.append(edge)
            } else if sourceInSelection || targetInSelection {
                boundaryEdges.append(edge)
            }
        }
        
        // 3. Create internal graph with selected nodes
        let internalGraph = NodeGraph()
        for nodeId in nodeIds {
            if let node = nodes[nodeId] {
                internalGraph.nodes[nodeId] = node
            }
        }
        for edge in internalEdges {
            internalGraph.edges[edge.id] = edge
        }
        
        // 4. Create exposed ports for boundary connections
        var exposedPorts: [NodePort] = []
        var portMappings: [String: (nodeId: UUID, portId: String)] = [:]
        
        for edge in boundaryEdges {
            if nodeIds.contains(edge.sourceNodeId) {
                let externalPortId = "out_\(edge.sourcePortId)"
                exposedPorts.append(
                    NodePort(
                        id: externalPortId,
                        label: "OUT",
                        signalType: edge.signalType,
                        direction: .output
                    )
                )
                portMappings[externalPortId] = (edge.sourceNodeId, edge.sourcePortId)
            }
            
            if nodeIds.contains(edge.targetNodeId) {
                let externalPortId = "in_\(edge.targetPortId)"
                exposedPorts.append(
                    NodePort(
                        id: externalPortId,
                        label: "IN",
                        signalType: edge.signalType,
                        direction: .input
                    )
                )
                portMappings[externalPortId] = (edge.targetNodeId, edge.targetPortId)
            }
        }
        
        // 5. Create macro node
        let macroNode = MacroNode(
            id: UUID(),
            name: name,
            internalGraph: internalGraph,
            exposedPorts: exposedPorts,
            portMappings: portMappings
        )
        
        // 6. Add macro to parent graph
        nodes[macroNode.id] = macroNode
        
        // 7. Update boundary edges to connect to macro instead of internal nodes
        for edge in boundaryEdges {
            if nodeIds.contains(edge.sourceNodeId) {
                let externalPortId = "out_\(edge.sourcePortId)"
                let newEdge = GraphEdge(
                    id: UUID(),
                    sourceNodeId: macroNode.id,
                    sourcePortId: externalPortId,
                    targetNodeId: edge.targetNodeId,
                    targetPortId: edge.targetPortId,
                    signalType: edge.signalType
                )
                edges[newEdge.id] = newEdge
            } else if nodeIds.contains(edge.targetNodeId) {
                let externalPortId = "in_\(edge.targetPortId)"
                let newEdge = GraphEdge(
                    id: UUID(),
                    sourceNodeId: edge.sourceNodeId,
                    sourcePortId: edge.sourcePortId,
                    targetNodeId: macroNode.id,
                    targetPortId: externalPortId,
                    signalType: edge.signalType
                )
                edges[newEdge.id] = newEdge
            }
            
            edges.removeValue(forKey: edge.id)
        }
        
        // 8. Remove original nodes and internal edges from parent graph
        for nodeId in nodeIds {
            nodes.removeValue(forKey: nodeId)
        }
        for edge in internalEdges {
            edges.removeValue(forKey: edge.id)
        }
        
        objectWillChange.send()
        return macroNode
    }
}

// MARK: - MacroNode Factory Methods

extension MacroNode {
    
    /// Create a pre-built macro-node from a LanePreset.
    static func fromPreset(preset: LanePreset) -> MacroNode {
        let graph = ImplicitGraphBuilder.buildGraph(from: preset)
        
        let outputPorts = [
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output),
            NodePort(id: "cv_level", label: "LEVEL", signalType: .control, direction: .output),
            NodePort(id: "cv_centroid", label: "CENTROID", signalType: .control, direction: .output),
            NodePort(id: "cv_flatness", label: "FLATNESS", signalType: .control, direction: .output),
            NodePort(id: "cv_flux", label: "FLUX", signalType: .control, direction: .output),
            NodePort(id: "cv_crest", label: "CREST", signalType: .control, direction: .output)
        ]
        
        let outputNode = graph.nodes.values.first { node in
            node.nodeType == "master_output"
        }
        
        var portMappings: [String: (nodeId: UUID, portId: String)] = [:]
        if let outputNode = outputNode {
            portMappings["out"] = (outputNode.id, "in")
        }
        
        let macro = MacroNode(
            id: UUID(),
            name: preset.name,
            internalGraph: graph,
            exposedPorts: outputPorts,
            portMappings: portMappings
        )
        
        // Store preset name AND internal node IDs for MacroNode parameter sync
        macro.parameters["presetName"] = preset.name

        // Export node IDs for MacroNode bidirectional parameter sync
        for node in graph.nodes.values {
            switch node.nodeType {
            case "oscillator", "noise", "silence":
                macro.parameters["sourceNodeId"] = node.id.uuidString
            case "ladder_filter":
                macro.parameters["ladderFilterNodeId"] = node.id.uuidString
            case "comb_filter":
                macro.parameters["combFilterNodeId"] = node.id.uuidString
            case "tunable_resonator":
                macro.parameters["resonatorNodeId"] = node.id.uuidString
            case "bit_crusher":
                macro.parameters["bitCrusherNodeId"] = node.id.uuidString
            case "delay_line":
                macro.parameters["delayNodeId"] = node.id.uuidString
            case "fft_analysis":
                macro.parameters["fftNodeId"] = node.id.uuidString
            case "semantic_eq":
                macro.parameters["semanticEQNodeId"] = node.id.uuidString
            case "spectral_saturation":
                macro.parameters["saturationNodeId"] = node.id.uuidString
            case "spectral_noise":
                macro.parameters["noiseNodeId"] = node.id.uuidString
            case "spectral_memory":
                macro.parameters["memoryNodeId"] = node.id.uuidString
            case "spectral_granularity":
                macro.parameters["granularityNodeId"] = node.id.uuidString
            default:
                break
            }
        }
        
        return macro
    }
    
    /// Convenience methods for creating factory presets.
    static func moogBass() -> MacroNode {
        fromPreset(preset: .moogBass)
    }
    
    static func arpLead() -> MacroNode {
        fromPreset(preset: .arpLead)
    }
    
    static func buchlaPerc() -> MacroNode {
        fromPreset(preset: .buchlaPerc)
    }
    
    static func rolandPad() -> MacroNode {
        fromPreset(preset: .rolandPad)
    }
    
    static func tb303Acid() -> MacroNode {
        fromPreset(preset: .tb303Acid)
    }
    
    static func noiseScape() -> MacroNode {
        fromPreset(preset: .noiseScape)
    }
    
    static func drumLane() -> MacroNode {
        fromPreset(preset: .drumLane)
    }
}

// MARK: - Envion-Inspired Stage Kind

/// Conceptual stage types for the Latent Resonator signal flow.
/// Inspired by Envion's modular design philosophy.
/// Each MacroNode can be tagged with a stageKind to indicate its role in the topology.
enum StageKind: String, Codable, CaseIterable {
    /// Source latent (e.g., KoenigSeed + Oscillator)
    /// The origin point of the signal - generates the initial excitation.
    case seed

    /// Neural core (e.g., FeedbackLoopNode)
    /// The recursive neural feedback loop - the "atom" of Latent Resonator.
    case resonator

    /// Spectral sculpting (e.g., SpectralChain nodes)
    /// Manipulates the frequency domain content.
    case spectra

    /// Analog filtering (e.g., LadderFilter + Agitation)
    /// Shapes the timbre through traditional subtractive synthesis.
    case ladder

    /// Temporal feedback (e.g., Delay + taps)
    /// Creates echo, delay, and time-based effects.
    case echo

    /// Direct output (e.g., MasterOutput, Mixer)
    /// Terminal stage - no further processing.
    case flat
}

// MARK: - Prompt Engine Integration (Whitepaper §4.2.2)

extension MacroNode {

    /// Reference to the PromptEngineNode in the internal graph, if present.
    var promptEngine: PromptEngineNode? {
        internalGraph.nodes.values.compactMap { $0 as? PromptEngineNode }.first
    }

    /// Reference to the ACEStepInferenceNode in the internal graph, if present.
    var inferenceNode: ACEStepInferenceNode? {
        internalGraph.nodes.values.compactMap { $0 as? ACEStepInferenceNode }.first
    }

    /// Current effective prompt based on spectral flatness.
    /// Returns empty string if no PromptEngineNode exists.
    var currentPrompt: String {
        guard let promptEngine = promptEngine else { return "" }
        return promptEngine.effectivePrompt
    }

    /// Current evolutionary phase (1, 2, or 3) based on flatness.
    var currentPromptPhase: Int {
        promptEngine?.currentPhase ?? 1
    }

    /// Update the prompt engine with current spectral flatness.
    /// This drives the 3-phase evolution per whitepaper §4.2.2.
    /// - Parameter flatness: Current spectral flatness (0.0 - 1.0)
    /// - Returns: The effective prompt for this flatness value
    @discardableResult
    func updatePromptForFlatness(_ flatness: Float) -> String {
        guard let promptEngine = promptEngine,
              let inferenceNode = inferenceNode else {
            return ""
        }

        // Update prompt engine flatness
        let effectivePrompt = promptEngine.updateFlatness(flatness)

        // Propagate to inference node
        inferenceNode.prompt = effectivePrompt

        return effectivePrompt
    }

    /// Set all three phase prompts programmatically.
    func setPrompts(phase1: String, phase2: String, phase3: String) {
        promptEngine?.phase1Prompt = phase1
        promptEngine?.phase2Prompt = phase2
        promptEngine?.phase3Prompt = phase3
        promptEngine?.objectWillChange.send()
    }

    /// Set phase transition thresholds.
    func setPhaseThresholds(phase1to2: Float, phase2to3: Float) {
        promptEngine?.phase1to2Threshold = phase1to2
        promptEngine?.phase2to3Threshold = phase2to3
        promptEngine?.objectWillChange.send()
    }
}

// MARK: - MacroNode Stage Extension

extension MacroNode {
    /// The conceptual stage kind of this macro node.
    /// Stored in the internalGraph metadata for persistence.
    var stageKind: StageKind? {
        get {
            internalGraph.metadata["stageKind"].flatMap { StageKind(rawValue: $0) }
        }
        set {
            internalGraph.metadata["stageKind"] = newValue?.rawValue
        }
    }

    /// A display name for this stage.
    /// Falls back to the node's name if not explicitly set.
    var stageDisplayName: String {
        get {
            internalGraph.metadata["stageDisplayName"] ?? name
        }
        set {
            internalGraph.metadata["stageDisplayName"] = newValue
        }
    }

    /// Returns a human-readable description of the stage.
    var stageDescription: String {
        guard let kind = stageKind else {
            return "Unclassified"
        }
        switch kind {
        case .seed:       return "Seed - Signal Origin"
        case .resonator:  return "Resonator - Neural Core"
        case .spectra:    return "Spectra - Frequency Sculpting"
        case .ladder:     return "Ladder - Analog Filter"
        case .echo:       return "Echo - Temporal Feedback"
        case .flat:       return "Flat - Direct Output"
        }
    }

    /// Color associated with this stage kind (for UI visualization).
    var stageColor: Color {
        guard let kind = stageKind else {
            return .gray
        }
        switch kind {
        case .seed:       return .yellow
        case .resonator:  return .cyan
        case .spectra:    return .purple
        case .ladder:     return .orange
        case .echo:       return .blue
        case .flat:       return .green
        }
    }
}
