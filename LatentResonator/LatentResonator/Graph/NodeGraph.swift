import Foundation
import SwiftUI
import Combine
import AVFoundation

// MARK: - Node Graph

/// The complete signal processing graph.
///
/// Thread safety:
/// - Mutations happen on main thread only
/// - Audio callbacks read node parameters (cached values)
/// - Control evaluation happens on timer thread (~60Hz)
///
/// Single source of truth: SETUP and PERFORM views are projections
/// of this graph. All parameter changes flow through here.
final class NodeGraph: ObservableObject {
    
    // MARK: - Graph State
    
    /// All nodes keyed by UUID. Type-erased via `any GraphNode`.
    @Published var nodes: [UUID: any GraphNode] = [:]
    
    /// All edges keyed by UUID.
    @Published var edges: [UUID: GraphEdge] = [:]

    // MARK: - Graph Metadata

    /// General purpose metadata storage for the graph.
    @Published var metadata: [String: String] = [:]
    
    /// Exposed controls for PERFORM view auto-generation.
    @Published var exposedControls: [ExposedControl] = []
    
    /// Macro bindings: one control → multiple targets with curves.
    @Published var macroBindings: [MacroBinding] = []
    
    // MARK: - Topology Change Notification
    
    /// Publishes when graph topology changes (add/remove nodes or edges).
    /// Subscribe to this for operations that should only run on topology changes,
    /// not on parameter changes.
    let topologyDidChange = PassthroughSubject<Void, Never>()
    
    /// Publishes when an audio parameter changes value (for AudioGraphMapper updates).
    /// Tuple: (nodeId, paramId, newValue)
    let parameterDidChange = PassthroughSubject<(UUID, String, Float), Never>()
    
    // MARK: - Auto-Save (Phase 0)
    
    /// Debounce interval for auto-save to avoid excessive disk writes
    private let saveDebounceInterval: TimeInterval = 0.5
    
    /// Dispatch work item for debounced save
    private var saveDebounceWorkItem: DispatchWorkItem?
    
    /// Cancellable for topology change subscription
    private var topologyChangeCancellable: AnyCancellable?
    
    // MARK: - Viewport State (for PATCH view persistence)
    
    var viewport: GraphViewport = GraphViewport()
    
    // MARK: - Lifecycle
    
    /// Whether auto-save is enabled (disabled for subgraphs/MacroNodes)
    private var autoSaveEnabled: Bool = true
    
    init(autoSaveEnabled: Bool = true) {
        self.autoSaveEnabled = autoSaveEnabled
        if autoSaveEnabled {
            setupAutoSave()
        }
    }
    
    /// Sets up auto-save subscription on topology changes with debounce
    private func setupAutoSave() {
        topologyChangeCancellable = topologyDidChange
            .sink { [weak self] in
                self?.triggerDebouncedSave()
            }
    }
    
    /// Triggers a debounced save operation
    private func triggerDebouncedSave() {
        // Skip save during active playback to prevent UI stutter
        // Only save when user is editing, not during performance
        
        // Cancel any pending save
        saveDebounceWorkItem?.cancel()
        saveDebounceWorkItem = nil
        
        // Create new work item
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NodeGraphStore.save(self)
        }
        
        // Schedule on main queue after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
        saveDebounceWorkItem = workItem
    }
    
    // MARK: - Validation
    
    /// Validates a proposed connection before creating the edge.
    /// Returns nil if valid, error string otherwise.
    func validateConnection(
        from source: (nodeId: UUID, portId: String),
        to target: (nodeId: UUID, portId: String)
    ) -> String? {

        // 1. Check both nodes exist
        guard let sourceNode = nodes[source.nodeId] else {
            return "Source node not found"
        }
        guard let targetNode = nodes[target.nodeId] else {
            return "Target node not found"
        }
        
        // 2. Check both ports exist
        guard let sourcePort = sourceNode.ports.first(where: { $0.id == source.portId }) else {
            return "Source port '\(source.portId)' not found"
        }
        guard let targetPort = targetNode.ports.first(where: { $0.id == target.portId }) else {
            return "Target port '\(target.portId)' not found"
        }
        
        // 3. Check port directions (source must be output, target must be input)
        guard sourcePort.direction == .output else {
            return "Source port must be an output"
        }
        guard targetPort.direction == .input else {
            return "Target port must be an input"
        }
        
        // 4. Check signal type compatibility
        guard sourcePort.signalType == targetPort.signalType else {
            return "Signal type mismatch: \(sourcePort.signalType) → \(targetPort.signalType)"
        }
        
        // 5. Check for existing connection to audio input (single-connection constraint)
        if targetPort.signalType == .audio {
            let existingConnection = edges.values.first { edge in
                edge.targetNodeId == target.nodeId && edge.targetPortId == target.portId
            }
            if existingConnection != nil {
                return "Audio input ports can only have one connection"
            }
        }
        
        // 6. Cycle detection (only FeedbackLoopNode may create cycles)
        let wouldCreateCycle = detectCycle(
            from: source.nodeId,
            to: target.nodeId,
            excludingEdge: nil
        )
        
        if wouldCreateCycle {
            // Check if target is a FeedbackLoopNode (allowed to create cycles)
            let targetIsFeedbackLoop = targetNode.nodeType == "feedback_loop"
            if !targetIsFeedbackLoop {
                return "Connection would create a cycle (only FEEDBACK LOOP nodes may have cycles)"
            }
        }
        
        return nil
    }
    
    /// Detects if connecting sourceNode → targetNode would create a cycle.
    /// Uses DFS from target back to source.
    private func detectCycle(
        from sourceId: UUID,
        to targetId: UUID,
        excludingEdge: UUID?
    ) -> Bool {
        var visited = Set<UUID>()
        return dfsHasCycle(current: targetId, target: sourceId, visited: &visited, excluding: excludingEdge)
    }
    
    private func dfsHasCycle(
        current: UUID,
        target: UUID,
        visited: inout Set<UUID>,
        excluding: UUID?
    ) -> Bool {
        if current == target { return true }
        if visited.contains(current) { return false }
        visited.insert(current)
        
        // Follow all edges where current is the source
        for edge in edges.values {
            if edge.id == excluding { continue }
            if edge.sourceNodeId == current {
                if dfsHasCycle(current: edge.targetNodeId, target: target, visited: &visited, excluding: excluding) {
                    return true
                }
            }
        }
        
        return false
    }
    
    // MARK: - Mutation API
    
    /// Apply a graph mutation with validation and audio graph rebuild if needed.
    func applyMutation(_ mutation: GraphMutation) throws {
        switch mutation {
        case .addNode(let id, let nodeType, let position, let params):
            try addNode(id: id, type: nodeType, position: position, params: params)
            
        case .removeNode(let id):
            removeNode(id: id)
            
        case .connectEdge(let edge):
            try connectEdge(edge)
            
        case .disconnectEdge(let id):
            disconnectEdge(id: id)
            
        case .setParameter(let nodeId, let paramId, let value):
            setNodeParameter(nodeId: nodeId, paramId: paramId, value: value)
        }
    }
    
    // MARK: - Node Management
    
    private func addNode(id: UUID, type: String, position: CGPoint, params: [String: Any]) throws {
        // Node factory will be implemented in NodeFactory.swift
        guard var node = NodeFactory.createNode(id: id, type: type, params: params) else {
            throw GraphError.unknownNodeType(type)
        }
        
        // Set position on created node
        node.x = position.x
        node.y = position.y
        
        nodes[id] = node
        objectWillChange.send()
        topologyDidChange.send()
    }
    
    func removeNode(id: UUID) {
        // Remove all edges connected to this node
        let connectedEdges = edges.values.filter { edge in
            edge.sourceNodeId == id || edge.targetNodeId == id
        }
        for edge in connectedEdges {
            edges.removeValue(forKey: edge.id)
        }
        
        // Remove the node
        nodes.removeValue(forKey: id)
        
        // Remove any exposed controls for this node
        exposedControls.removeAll { $0.nodeId == id }
        
        objectWillChange.send()
        topologyDidChange.send()
    }
    
    // MARK: - Macro Expansion
    
    /// Expand a MacroNode to reveal its internal topology.
    /// Internal nodes are added to the main graph with their positions offset
    /// by the macro's position. External connections to the macro are preserved.
    func expand(macroId: UUID) throws {
        guard let macroNode = nodes[macroId] as? MacroNode else {
            throw GraphError.invalidConnection("Node is not a MacroNode or doesn't exist")
        }
        
        // Toggle expansion state
        macroNode.isExpanded = !macroNode.isExpanded
        macroNode.parameters["isExpanded"] = macroNode.isExpanded
        
        if macroNode.isExpanded {
            // Get macro's position to offset internal nodes
            let macroX = macroNode.x
            let macroY = macroNode.y
            
            // Add ONLY control nodes to main graph (audio stays black-boxed in MacroNode)
            // Control nodes: agitation, peak, manual_control (LFOs, envelopes, manual knobs)
            for (_, var internalNode) in macroNode.internalGraph.nodes {
                // Filter: only show control-rate nodes, not audio processing nodes
                if internalNode.category == .control {
                    // Offset internal node position by macro's position
                    internalNode.x = macroX + 250 + (internalNode.x * 0.3)  // Offset right and scale down
                    internalNode.y = macroY + (internalNode.y * 0.3)
                    
                    // Mark node as belonging to this macro (for visual grouping)
                    internalNode.parameters["parentMacroId"] = macroId.uuidString
                    
                    nodes[internalNode.id] = internalNode
                }
            }
            
            // Add control edges only (edges between control nodes)
            for (_, edge) in macroNode.internalGraph.edges {
                // Only add edge if both ends are control nodes
                if let sourceNode = macroNode.internalGraph.nodes[edge.sourceNodeId],
                   let targetNode = macroNode.internalGraph.nodes[edge.targetNodeId],
                   sourceNode.category == .control && targetNode.category == .control {
                    edges[edge.id] = edge
                }
            }
            
            // Keep the macro visible but marked as expanded (UI shows green border)
            
        } else {
            // Collapse: remove control nodes and edges
            let internalNodeIds = Set(macroNode.internalGraph.nodes.keys)
            
            for nodeId in internalNodeIds {
                guard let internalNode = macroNode.internalGraph.nodes[nodeId],
                      internalNode.category == .control else {
                    continue  // Only remove control nodes (audio nodes were never added)
                }
                
                // Remove from main graph (but keep in internalGraph)
                let connectedEdges = edges.values.filter { edge in
                    edge.sourceNodeId == nodeId || edge.targetNodeId == nodeId
                }
                for edge in connectedEdges {
                    edges.removeValue(forKey: edge.id)
                }
                nodes.removeValue(forKey: nodeId)
            }
            
            macroNode.parameters.removeValue(forKey: "isExpanded")
        }
        
        objectWillChange.send()
    }
    
    // MARK: - Edge Management
    
    func connectEdge(_ edge: GraphEdge) throws {
        // Validate before adding
        if let error = validateConnection(
            from: (edge.sourceNodeId, edge.sourcePortId),
            to: (edge.targetNodeId, edge.targetPortId)
        ) {
            throw GraphError.invalidConnection(error)
        }

        edges[edge.id] = edge

        // Notify affected nodes
        updateNodeTopology(nodeId: edge.sourceNodeId)
        updateNodeTopology(nodeId: edge.targetNodeId)

        objectWillChange.send()
        topologyDidChange.send()
    }
    
    func disconnectEdge(id: UUID) {
        guard let edge = edges[id] else { return }

        edges.removeValue(forKey: id)

        // Notify affected nodes
        updateNodeTopology(nodeId: edge.sourceNodeId)
        updateNodeTopology(nodeId: edge.targetNodeId)

        objectWillChange.send()
        topologyDidChange.send()
    }
    
    private func updateNodeTopology(nodeId: UUID) {
        guard nodes[nodeId] != nil else { return }
        // Topology change tracking placeholder for future node notifications
        // Inputs/outputs calculation reserved for future use:
        // let inputs = edges.values.filter { $0.targetNodeId == nodeId }...
        // let outputs = edges.values.filter { $0.sourceNodeId == nodeId }...
    }
    
    // MARK: - Parameter Management
    
    /// Get parameter value from any node as Float.
    /// Thread-safe for reads (returns optional value).
    func getParameter(nodeId: UUID, key: String) -> Float? {
        guard let node = nodes[nodeId] else { return nil }
        return node.parameters[key] as? Float
    }
    
    /// Get raw parameter value (Any type) from node.
    func getParameterValue(nodeId: UUID, key: String) -> Any? {
        guard let node = nodes[nodeId] else { return nil }
        return node.parameters[key]
    }
    
    /// Set parameter value on any node. Emits change notifications for UI and audio graph.
    /// Must be called from main thread.
    func setParameter(nodeId: UUID, key: String, value: Float) {
        guard var node = nodes[nodeId] else { return }
        
        // Update parameter
        node.parameters[key] = value
        nodes[nodeId] = node  // Write back the modified node
        
        // Notify UI observers
        objectWillChange.send()
        
        // Notify audio graph if this parameter affects audio topology
        if isAudioParameter(key) {
            parameterDidChange.send((nodeId, key, value))
        }
    }
    
    /// Legacy parameter setter for Any values (kept for backward compatibility).
    /// v2.0: Use setParameter(nodeId:key:value:) for new code.
    func setNodeParameter(nodeId: UUID, paramId: String, value: Any) {
        guard nodes[nodeId] != nil else { return }

        // Update node parameter directly
        nodes[nodeId]?.parameters[paramId] = value

        // Emit parameter change for v2.0 audio graph rebuilds
        if let floatValue = value as? Float, isAudioParameter(paramId) {
            parameterDidChange.send((nodeId, paramId, floatValue))
        }

        // Apply macro bindings if this is an exposed control
        if let exposedControl = exposedControls.first(where: { $0.nodeId == nodeId && $0.paramId == paramId }),
           let floatValue = value as? Float {
            applyMacroBinding(exposedControlId: exposedControl.id, value: floatValue)
        }

        objectWillChange.send()
    }
    
    func getNodeParameter(nodeId: UUID, paramId: String) -> Any? {
        return nodes[nodeId]?.parameters[paramId]
    }
    
    // MARK: - Parameter Helpers
    
    /// Determines if a parameter change should trigger an audio graph rebuild.
    /// Audio topology parameters (cutoff, resonance, delay time, etc.) require graph rebuilds.
    private func isAudioParameter(_ key: String) -> Bool {
        let audioParams = [
            "cutoff", "resonance", "drive", "mode",
            "delayTime", "delayFeedback", "delayMix",
            "combFeedback", "combTapCount", "baseDelay",
            "saturationMorph", "bitCrushDepth"
        ]
        return audioParams.contains(key)
    }
    
    // MARK: - Exposed Controls
    
    func addExposedControl(_ control: ExposedControl) {
        exposedControls.append(control)
        objectWillChange.send()
    }
    
    func removeExposedControl(id: UUID) {
        exposedControls.removeAll { $0.id == id }
        macroBindings.removeAll { $0.exposedControlId == id }
        objectWillChange.send()
    }
    
    /// Auto-generate exposed controls for all parameters of a MacroNode and its internal nodes.
    /// Called by NeuralEngine to populate the PERFORM surface.
    /// - Parameter macroNode: The MacroNode to generate controls for
    func autoGenerateExposedControls(for macroNode: MacroNode) {
        // Remove any existing exposed controls for this node
        exposedControls.removeAll { control in
            // Check if control belongs to this MacroNode or its internal nodes
            control.nodeId == macroNode.id ||
            macroNode.internalGraph.nodes.keys.contains(control.nodeId)
        }

        // 1. Expose MacroNode's own parameters (texture, chaos, warmth, etc.)
        var positionCounter = 0
        for (paramId, value) in macroNode.parameters {
            let control = ExposedControl(
                id: UUID(),
                nodeId: macroNode.id,
                paramId: paramId,
                label: paramId.capitalized,
                controlType: inferControlType(for: paramId, value: value),
                range: inferRange(for: paramId),
                defaultValue: value as? Float ?? 0.5,
                midiCC: nil,
                position: positionCounter
            )
            exposedControls.append(control)
            positionCounter += 1
        }

        // 2. Expose internal node parameters with musical names
        for (internalNodeId, node) in macroNode.internalGraph.nodes {
            // Skip utility nodes
            guard !node.nodeType.contains("utility") else { continue }

            for (paramId, value) in node.parameters {
                // Create human-readable label
                let label = createMusicalLabel(nodeType: node.nodeType, paramId: paramId)

                let control = ExposedControl(
                    id: UUID(),
                    nodeId: internalNodeId,
                    paramId: paramId,
                    label: label,
                    controlType: inferControlType(for: paramId, value: value),
                    range: inferRange(for: paramId),
                    defaultValue: value as? Float ?? 0.5,
                    midiCC: nil,
                    position: positionCounter
                )
                exposedControls.append(control)
                positionCounter += 1
            }
        }
        
        objectWillChange.send()
    }

    /// Auto-generate exposed controls for all top-level nodes in the graph.
    /// Used when loading legacy graphs or templates without macros.
    func autoGenerateExposedControlsForMainGraph() {
        // Clear existing exposed controls
        exposedControls.removeAll()

        var positionCounter = 0

        // Expose parameters from all audio-generating nodes
        for (nodeId, node) in nodes {
            // Skip utility/routing nodes without audio parameters
            guard !node.nodeType.contains("utility"),
                  !node.nodeType.contains("macro"),
                  !node.nodeType.contains("master") else { continue }

            for (paramId, value) in node.parameters {
                // Create human-readable label
                let label = createMusicalLabel(nodeType: node.nodeType, paramId: paramId)

                let control = ExposedControl(
                    id: UUID(),
                    nodeId: nodeId,
                    paramId: paramId,
                    label: label,
                    controlType: inferControlType(for: paramId, value: value),
                    range: inferRange(for: paramId),
                    defaultValue: value as? Float ?? 0.5,
                    midiCC: nil,
                    position: positionCounter
                )
                exposedControls.append(control)
                positionCounter += 1
            }
        }

        print("[NodeGraph] Auto-generated \(exposedControls.count) exposed controls for main graph")
        objectWillChange.send()
    }

    /// Create a human-readable musical label for a parameter.
    private func createMusicalLabel(nodeType: String, paramId: String) -> String {
        // Map technical IDs to musical terms
        let mappings: [String: [String: String]] = [
            "tunable_resonator": [
                "note": "Pitch",
                "decay": "Decay",
                "brightness": "Tone",
                "stretch": "Stretch"
            ],
            "ladder_filter": [
                "cutoff": "Cutoff",
                "resonance": "Resonance",
                "drive": "Drive"
            ],
            "bit_crusher": [
                "bitDepth": "Bits",
                "sampleRate": "Rate"
            ],
            "semantic_eq": [
                "lowGain": "Low",
                "midGain": "Mid",
                "highGain": "High"
            ]
        ]
        
        if let nodeMappings = mappings[nodeType],
           let label = nodeMappings[paramId] {
            return label
        }
        
        // Fallback: capitalize and clean up
        return paramId
            .replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
            .capitalized
    }
    
    /// Infer the appropriate control widget type based on parameter name and value.
    private func inferControlType(for paramId: String, value: Any) -> ControlWidget {
        // Toggles for boolean parameters
        if paramId.contains("enabled") || paramId.contains("active") || paramId.contains("bypass") {
            return .toggle
        }
        
        // XY pad for paired parameters
        if paramId.contains("X") || paramId.contains("Y") {
            return .xyPad
        }
        
        // Dropdown for mode/enum parameters
        if paramId.contains("mode") || paramId.contains("type") {
            return .dropdown
        }
        
        // Default to knob for numeric parameters
        return .knob
    }
    
    /// Infer the appropriate value range for a parameter.
    private func inferRange(for paramId: String) -> ClosedRange<Float> {
        switch paramId {
        case "texture", "chaos", "warmth", "bias", "mix", "drive", "probability":
            return 0.0...1.0
        case "cutoff", "frequency", "rate":
            return 20.0...20000.0
        case "resonance", "depth", "amount", "gain":
            return 0.0...2.0
        case "decay", "attack", "release":
            return 0.001...5.0
        case "note", "pitch", "semitones":
            return 0.0...127.0
        case "steps":
            return 1.0...64.0
        default:
            return 0.0...1.0
        }
    }
    
    // MARK: - Macro Bindings
    
    func addMacroBinding(_ binding: MacroBinding) {
        macroBindings.append(binding)
        objectWillChange.send()
    }
    
    func applyMacroBinding(exposedControlId: UUID, value: Float) {
        guard let binding = macroBindings.first(where: { $0.exposedControlId == exposedControlId }) else {
            return
        }
        
        for target in binding.targets {
            let scaled = scaleValue(
                value,
                from: target.inputRange,
                to: target.outputRange,
                curve: target.curve
            )
            setNodeParameter(nodeId: target.nodeId, paramId: target.paramId, value: scaled)
        }
    }
    
    private func scaleValue(
        _ v: Float,
        from: ClosedRange<Float>,
        to: ClosedRange<Float>,
        curve: ScalingCurve
    ) -> Float {
        let normalized = (v - from.lowerBound) / (from.upperBound - from.lowerBound)
        let shaped: Float
        
        switch curve {
        case .linear:
            shaped = normalized
        case .exponential:
            shaped = normalized * normalized
        case .logarithmic:
            shaped = log2f(1 + normalized) / log2f(2)
        case .inverted:
            shaped = 1 - normalized
        case .sCurve:
            shaped = 3 * normalized * normalized - 2 * normalized * normalized * normalized
        }
        
        return to.lowerBound + shaped * (to.upperBound - to.lowerBound)
    }
    
    // MARK: - Node Lookup

    /// Find a node by ID in the graph.
    /// - Returns: The node if found, nil otherwise
    func findNode(_ nodeId: UUID) -> (any GraphNode)? {
        return nodes[nodeId]
    }

    /// Set position for a node in the graph.
    /// - Parameters:
    ///   - nodeId: The node ID
    ///   - x: X position
    ///   - y: Y position
    func setNodePosition(id nodeId: UUID, x: Double, y: Double) {
        guard nodes[nodeId] != nil else { return }
        nodes[nodeId]?.x = x
        nodes[nodeId]?.y = y
        objectWillChange.send()
    }
    
    // MARK: - Serialization

    func serialize() -> SerializedGraph {
        let positions = nodes.values.map { ["id": $0.id.uuidString, "x": $0.x, "y": $0.y] }
        print("NodeGraph.serialize: nodeCount=\(nodes.count) edgeCount=\(edges.count) positions=\(positions)")

        return SerializedGraph(
            version: "2.0.0",
            nodes: nodes.values.map { SerializedNode(from: $0) },
            edges: Array(edges.values),
            exposedControls: exposedControls,
            macroBindings: macroBindings,
            viewport: viewport
        )
    }
    
    func deserialize(_ data: SerializedGraph) throws {
        // Clear existing state
        nodes.removeAll()
        edges.removeAll()
        exposedControls.removeAll()
        macroBindings.removeAll()

        // Reconstruct nodes
        for serialized in data.nodes {
            // Convert [String: CodableValue] to [String: Any] for NodeFactory
            let params: [String: Any] = serialized.parameters.mapValues { $0.anyValue }

            guard var node = NodeFactory.createNode(
                id: serialized.id,
                type: serialized.nodeType,
                params: params
            ) else {
                throw GraphError.unknownNodeType(serialized.nodeType)
            }
            node.name = serialized.displayName
            node.x = serialized.position.x
            node.y = serialized.position.y
            nodes[node.id] = node
        }

        // Reconstruct edges
        for edge in data.edges {
            do {
                try connectEdge(edge)
            } catch {
                throw error
            }
        }

        // Restore exposed controls and bindings
        exposedControls = data.exposedControls
        macroBindings = data.macroBindings
        viewport = data.viewport

        objectWillChange.send()
    }
    
    // MARK: - Topology Analysis

    /// Returns nodes in topological order (sources first, sinks last).
    /// Used by AudioGraphMapper to connect nodes in correct order.
    func topologicalSort() -> [UUID] {
        var sorted: [UUID] = []
        var visited = Set<UUID>()
        var temp = Set<UUID>()

        func visit(_ nodeId: UUID) {
            if temp.contains(nodeId) {
                // Cycle detected (should be prevented by validation)
                return
            }
            if visited.contains(nodeId) { return }

            temp.insert(nodeId)

            // Visit all nodes that this node depends on (its inputs)
            for edge in edges.values where edge.targetNodeId == nodeId {
                visit(edge.sourceNodeId)
            }

            temp.remove(nodeId)
            visited.insert(nodeId)
            sorted.append(nodeId)
        }

        // Visit all nodes
        for nodeId in nodes.keys {
            visit(nodeId)
        }

        return sorted
    }

    /// Get all edges connected to a node.
    func edges(for nodeId: UUID) -> (inputs: [GraphEdge], outputs: [GraphEdge]) {
        let inputs = edges.values.filter { $0.targetNodeId == nodeId }
        let outputs = edges.values.filter { $0.sourceNodeId == nodeId }
        return (Array(inputs), Array(outputs))
    }
}

// MARK: - Serialization Types

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

    init(from node: any GraphNode) {
        self.id = node.id
        self.nodeType = node.nodeType
        self.displayName = node.name

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
    // The KickstartTemplate.json ships with `"position": [x, y]` (array format),
    // but Swift 5.9+'s SDK `CGPoint: Codable` uses keyed form `{"x":..., "y":...}`.
    // Without this custom decoder the template fails to load silently and the
    // app falls through to the emergency graph. We accept either format on
    // decode and emit the object form on encode (matches SDK default).

    private enum CodingKeys: String, CodingKey {
        case id, nodeType, displayName, parameters, position
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.nodeType = try container.decode(String.self, forKey: .nodeType)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.parameters = try container.decode([String: CodableValue].self, forKey: .parameters)

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

// MARK: - Node Factory

/// Factory for creating nodes from type strings.
/// Extended as new node types are implemented.
enum NodeFactory {
    static func createNode(
        id: UUID,
        type: String,
        params: [String: Any],
        mainMixer: AVAudioMixerNode? = nil,
        inputNode: AVAudioInputNode? = nil
    ) -> (any GraphNode)? {
        switch type {
        case "oscillator":
            return OscillatorNode(id: id, params: params)
        case "koenig_seed":
            return KoenigSeedNode(id: id, params: params)
        case "markov_sequencer":
            return MarkovSequencerNode(id: id, params: params)
        case "gesture_recorder":
            return GestureRecorderNode(id: id, params: params)
        case "noise":
            return NoiseNode(id: id, params: params)
        case "silence":
            return SilenceNode(id: id, params: params)
        case "audio_input":
            return AudioInputNode(id: id, params: params, engineInputNode: inputNode)
        case "mixer":
            return MixerNode(id: id, params: params)
        case "master_output":
            let name = params["displayName"] as? String ?? "Master Out"
            let x = params["x"] as? Double ?? 0
            let y = params["y"] as? Double ?? 0
            let node = MasterOutputNode(id: id, name: name, x: x, y: y)
            // Copy any volume/threshold params
            if let volume = params["volume"] as? Float {
                node.setParam("volume", value: volume)
            }
            if let threshold = params["limiterThreshold"] as? Float {
                node.setParam("limiterThreshold", value: threshold)
            }
            return node
        case "passthrough":
            return PassthroughNode(id: id, params: params)
        case "fft_analysis":
            return FFTAnalysisNode(id: id, params: params)
        case "semantic_eq":
            return SemanticEQNode(id: id, params: params)
        case "spectral_saturation":
            return SpectralSaturationNode(id: id, params: params)
        case "spectral_noise":
            return SpectralNoiseNode(id: id, params: params)
        case "spectral_memory":
            return SpectralMemoryNode(id: id, params: params)
        case "spectral_granularity":
            return SpectralGranularityNode(id: id, params: params)
        case "spectral_freeze":
            return SpectralFreezeNode(id: id, params: params)
        case "ifft_synthesis":
            return IFFTSynthesisNode(id: id, params: params)
        case "ladder_filter":
            return LadderFilterNode(id: id, params: params)
        case "comb_filter":
            return CombFilterNode(id: id, params: params)
        case "tunable_resonator":
            return TunableResonatorNode(id: id, params: params)
        case "bit_crusher":
            return BitCrusherNode(id: id, params: params)
        case "waveshaper":
            return WaveshaperNode(id: id, params: params)
        case "delay_line":
            return DelayLineNode(id: id, params: params)
        case "ace_step_inference":
            return ACEStepInferenceNode(id: id, params: params)
        case "prompt_engine":
            return PromptEngineNode(id: id, params: params)
        case "prompt_bank":
            return PromptBankNode(id: id)
        case "macro":
            // Try complex deserialization first (for saved graphs with full macro data)
            if let name = params["name"] as? String,
               let _ = params["internalGraph"] as? [String: Any],
               let exposedPortsData = params["exposedPorts"] as? [[String: Any]],
               let portMappingsData = params["portMappings"] as? [String: [String: String]] {

                let internalGraph = NodeGraph(autoSaveEnabled: false)
                let exposedPorts = exposedPortsData.compactMap { portData -> NodePort? in
                    guard let id = portData["id"] as? String,
                          let label = portData["label"] as? String,
                          let signalTypeRaw = portData["signalType"] as? String,
                          let directionRaw = portData["direction"] as? String,
                          let signalType = SignalType(rawValue: signalTypeRaw),
                          let direction = PortDirection(rawValue: directionRaw) else {
                        return nil
                    }
                    return NodePort(id: id, label: label, signalType: signalType, direction: direction)
                }
                
                var portMappings: [String: (nodeId: UUID, portId: String)] = [:]
                for (externalPortId, mapping) in portMappingsData {
                    guard let nodeIdString = mapping["nodeId"],
                          let nodeId = UUID(uuidString: nodeIdString),
                          let portId = mapping["portId"] else {
                        continue
                    }
                    portMappings[externalPortId] = (nodeId, portId)
                }
                
                return MacroNode(
                    id: id,
                    name: name,
                    internalGraph: internalGraph,
                    exposedPorts: exposedPorts,
                    portMappings: portMappings
                )
            }
            // Fallback to simple deserialization (uses MacroNode's convenience init)
            return MacroNode(id: id, params: params)
        case "feedback_loop":
            return FeedbackLoopNode(id: id, params: params)
        case "agitation":
            return AgitationNode(id: id, params: params)
        case "peak":
            return PeakNode(id: id, params: params)
        case "manual_control":
            return ManualControlNode(id: id, params: params)
        case "meta_parameter":
            return MetaParameterNode(id: id, params: params)
        case "step_sequencer":
            return SequencerNode(id: id, params: params)
        case "spectral_analyzer":
            return SpectralAnalyzerNode(id: id, params: params)
        case "spectral_chain":
            return SpectralChainNode(id: id, params: params)
        default:
            return nil
        }
    }
}
