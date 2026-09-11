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

    // MARK: - Neural Bridge

    /// Shared ACE-Step bridge, assigned by `NeuralEngine` before any node is
    /// created. `NodeFactory.createNode(...)` reads this to inject `bridge:`
    /// into `ACEStepInferenceNode`/`FeedbackLoopNode` at construction time;
    /// `wireNeuralNodes()` re-applies it (and connects the two node types to
    /// each other) after every deserialize/addNode, idempotently.
    weak var aceBridge: ACEStepBridge?

    /// Shared audio input ring buffer, assigned by `NeuralEngine` before any
    /// node is created. `NodeFactory.createNode(...)` reads this to inject
    /// `audioInputBuffer:` into `AudioInputNode` at construction time.
    var audioInputBuffer: CircularAudioBuffer?

    // MARK: - Topology Change Notification
    
    /// Publishes when graph topology changes (add/remove nodes or edges).
    /// Subscribe to this for operations that should only run on topology changes,
    /// not on parameter changes.
    let topologyDidChange = PassthroughSubject<Void, Never>()
    
    // A `parameterDidChange` subject used to live here, publishing
    // (nodeId, paramId, newValue) "for ExecutionPlan rebuilds" whenever
    // `setParameter`/`setNodeParameter` touched an "audio parameter". It had
    // zero subscribers (perimeter audit, 2026-07-21) — a leftover from the
    // abandoned `AudioGraphMapper` design, whose `updateParameter()` did
    // incremental `AVAudioEngine` node updates (see `docs/E2E_COHESION_ANALYSIS.md` —
    // superseded, cited for historical context only; THIS file is the source of truth).
    // Removed rather than wired up: `ExecutionPlan` never caches parameter
    // *values*, only topology (buffer-slot assignment). Every `Step.dspNode`
    // is a live reference to the same `GraphNode` instance the UI mutates via
    // `setParam`/`setParameter`, so `DSPNode.render(...)` reads the current
    // value on the very next audio block via `getParam` — no rebuild needed.
    // Parameter changes are eventual-consistent by design, one buffer
    // (<= ~1s at `LRConstants.bufferSize`) after the UI edit. Only actual
    // topology changes (add/remove node or edge) require a plan rebuild —
    // that's `topologyDidChange`, above, which IS subscribed
    // (`NeuralEngine.rebuildAudioGraphIfNeeded()`).
    
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
        guard var node = NodeFactory.createNode(
            id: id,
            type: type,
            params: params,
            bridge: aceBridge,
            audioInputBuffer: audioInputBuffer
        ) else {
            throw GraphError.unknownNodeType(type)
        }
        
        // Set position on created node
        node.x = position.x
        node.y = position.y
        
        nodes[id] = node
        wireNeuralNodes()
        objectWillChange.send()
        topologyDidChange.send()
    }

    /// Public entry point for canvas-driven node insertion. Generates a fresh
    /// UUID, delegates to the private factory path, and returns the new id so
    /// the caller (e.g. `PatchCanvasView`'s right-click palette) can focus the
    /// newly added node. Returns `nil` if the type is unknown.
    @discardableResult
    func addNode(type: String, position: CGPoint, params: [String: Any] = [:]) -> UUID? {
        let id = UUID()
        do {
            try addNode(id: id, type: type, position: position, params: params)
            return id
        } catch {
            return nil
        }
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
    ///
    /// v2.0 fix (Fix 4): previously only `.control`-category internal nodes
    /// were promoted to the main graph, so the internal audio chain
    /// (oscillator → feedback_loop → mixer → master_output) stayed
    /// black-boxed and was never seen by `ExecutionPlan.build` — meaning
    /// an expanded macro still rendered silence in the pull-render engine.
    /// We now promote every internal node EXCEPT the internal
    /// `MasterOutputNode`: promoting a second master_output would make
    /// `ExecutionPlan.build`'s terminal-node pick (first `MasterOutputNode`
    /// in topo order) non-deterministic between the main graph's master and
    /// the macro's internal one, potentially silencing the main mix. The
    /// internal chain's terminal edge (mixer.out → internal master_output.in)
    /// is therefore intentionally dropped on promotion; the promoted
    /// internal nodes are DSP-active on the canvas for editing.
    ///
    /// Fix 4a (closed): when COLLAPSED, the macro itself now renders its
    /// `internalGraph` through its own cached internal `ExecutionPlan`
    /// (see `MacroNode.render` / `rebuildInternalPlanIfNeeded`), so a
    /// collapsed macro's audio reaches the main output without promoting
    /// any nodes. When EXPANDED, the macro emits silence and the promoted
    /// internal nodes are the live path. Expand/collapse behavior is
    /// unchanged.
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
            
            // Promote internal nodes to the main graph. We skip the
            // internal `MasterOutputNode` to avoid a second terminal
            // candidate in ExecutionPlan.build (see method doc). Every
            // other node — control AND audio — is promoted so the internal
            // signal chain is visible and DSP-active on the canvas.
            for (_, var internalNode) in macroNode.internalGraph.nodes {
                if internalNode is MasterOutputNode { continue }
                
                // Offset internal node position by macro's position
                internalNode.x = macroX + 250 + (internalNode.x * 0.3)
                internalNode.y = macroY + (internalNode.y * 0.3)
                
                // Mark node as belonging to this macro (for visual grouping
                // and for collapse() to find promoted nodes reliably).
                internalNode.parameters["parentMacroId"] = macroId.uuidString
                
                nodes[internalNode.id] = internalNode
            }
            
            // Promote internal edges whose both endpoints were promoted
            // (i.e., neither endpoint is the skipped internal master_output).
            for (_, edge) in macroNode.internalGraph.edges {
                guard let sourceNode = macroNode.internalGraph.nodes[edge.sourceNodeId],
                      let targetNode = macroNode.internalGraph.nodes[edge.targetNodeId],
                      !(sourceNode is MasterOutputNode),
                      !(targetNode is MasterOutputNode) else {
                    continue
                }
                edges[edge.id] = edge
            }
            
            // Keep the macro visible but marked as expanded (UI shows green border)
            
        } else {
            // Collapse: remove every node promoted from this macro (tagged
            // with `parentMacroId`), regardless of category. Previously only
            // `.control` nodes were removed, which left promoted audio
            // nodes stranded in the main graph after a collapse.
            let macroIdString = macroId.uuidString
            let promotedIds = nodes.values
                .filter { ($0.parameters["parentMacroId"] as? String) == macroIdString }
                .map { $0.id }
            
            for nodeId in promotedIds {
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
        // Fix P1 #4: expand/collapse mutates which nodes are in the parent
        // graph (and which edges are live), so the parent ExecutionPlan and
        // every macro's internalPlan must be rebuilt. Without this,
        // NeuralEngine.rebuildAudioGraphIfNeeded never runs and the audio
        // thread keeps rendering a stale plan (silence after expand/collapse).
        topologyDidChange.send()
    }

    /// Scoped inverse of `expand(macroId:)`. Removes the nodes and edges that
    /// were promoted by the expand (tagged with `parentMacroId`) and restores
    /// the macro node from the provided snapshot. The internal graph is not
    /// restored here because `expand` never mutates it; the snapshot is kept
    /// by `ExpandMacroCommand` for full-graph fallback if ever needed.
    func collapseExpanded(macroId: UUID, restoring macroSnapshot: SerializedNode) {
        guard let macroNode = nodes[macroId] as? MacroNode else { return }

        let macroIdString = macroId.uuidString
        let promotedIds = nodes.values
            .filter { ($0.parameters["parentMacroId"] as? String) == macroIdString }
            .map { $0.id }

        for nodeId in promotedIds {
            let connectedEdges = edges.values.filter { edge in
                edge.sourceNodeId == nodeId || edge.targetNodeId == nodeId
            }
            for edge in connectedEdges {
                edges.removeValue(forKey: edge.id)
            }
            nodes.removeValue(forKey: nodeId)
        }

        // Restore macro node properties from the snapshot.
        macroNode.name = macroSnapshot.displayName
        macroNode.x = Double(macroSnapshot.position.x)
        macroNode.y = Double(macroSnapshot.position.y)
        macroNode.stageKind = macroSnapshot.stageKind
        var restoredParameters: [String: Any] = [:]
        for (key, value) in macroSnapshot.parameters {
            restoredParameters[key] = value.anyValue
        }
        macroNode.parameters = restoredParameters
        macroNode.isExpanded = false
        macroNode.parameters["isExpanded"] = false

        objectWillChange.send()
        topologyDidChange.send()
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

    // MARK: - Neural Node Wiring

    /// Idempotently connects every `FeedbackLoopNode` in the graph to the
    /// shared `aceBridge` and to an available `ACEStepInferenceNode` (for
    /// parameter sync). Called after `deserialize(_:)` and `addNode(...)`
    /// so a graph built without a hand-authored edge between the two node
    /// types still ends up wired -- reassigning the same references on a
    /// repeat call is a no-op in effect.
    private func wireNeuralNodes() {
        let inferenceNode = nodes.values.compactMap { $0 as? ACEStepInferenceNode }.first
        inferenceNode?.bridge = aceBridge

        for node in nodes.values {
            guard let feedbackLoop = node as? FeedbackLoopNode else { continue }
            feedbackLoop.bridge = aceBridge
            if let inferenceNode = inferenceNode {
                feedbackLoop.connectInferenceNode(inferenceNode)
            }
        }
    }
    
    // MARK: - Parameter Management
    
    /// Get parameter value from any node as Float.
    /// Coerces Double, Int, and NSNumber to Float. Bool is intentionally
    /// not coerced (it is not a numeric parameter type).
    func getParameter(nodeId: UUID, key: String) -> Float? {
        guard let node = nodes[nodeId] else { return nil }
        guard let value = node.parameters[key] else { return nil }

        // Bool is not a numeric parameter; do not coerce to 0/1.
        if value is Bool { return nil }

        if let float = value as? Float { return float }
        if let double = value as? Double { return Float(double) }
        if let int = value as? Int { return Float(int) }
        if let number = value as? NSNumber { return number.floatValue }
        return nil
    }
    
    /// Get raw parameter value (Any type) from node.
    func getParameterValue(nodeId: UUID, key: String) -> Any? {
        guard let node = nodes[nodeId] else { return nil }
        return node.parameters[key]
    }
    
    /// Set parameter value on any node. Emits `objectWillChange` for UI observers;
    /// the audio thread picks up the new value on its own via `getParam` (no
    /// separate audio-graph notification — see comment above `topologyDidChange`).
    /// Must be called from main thread.
    func setParameter(nodeId: UUID, key: String, value: Float) {
        guard var node = nodes[nodeId] else { return }
        
        // Update parameter
        node.parameters[key] = value
        nodes[nodeId] = node  // Write back the modified node
        
        // Notify UI observers
        objectWillChange.send()
        
        // No audio-graph notification needed: the audio thread reads this
        // same node's parameters fresh via `getParam` on its next render
        // block (eventual-consistent by design — see the comment above
        // `topologyDidChange`/`parameterDidChange`'s old declaration).
    }
    
    /// Legacy parameter setter for Any values (kept for backward compatibility).
    /// v2.0: Use setParameter(nodeId:key:value:) for new code.
    func setNodeParameter(nodeId: UUID, paramId: String, value: Any) {
        guard nodes[nodeId] != nil else { return }

        // Update node parameter directly
        nodes[nodeId]?.parameters[paramId] = value

        // No audio-graph rebuild needed here either — same reasoning as
        // `setParameter(nodeId:key:value:)` above.

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
    
    /// Curated set of parameter IDs that define a macro's perform identity.
    /// These are the only parameters auto-exposed by default; everything else
    /// is opt-in via the canvas context menu (Wave A W3).
    private static let identityParameterIds: Set<String> = [
        "guidanceScale", "cfg",
        "feedback", "feedbackAmount",
        "entropy", "granularity"
    ]

    private static func isIdentityParameter(_ paramId: String) -> Bool {
        identityParameterIds.contains(paramId)
    }

    /// Auto-generate exposed controls for a MacroNode's identity parameters only.
    /// Called by NeuralEngine when a macro is added or a factory macro topology is
    /// loaded without explicit `exposedControls`.
    ///
    /// v2.0 Wave C: the previous all-floats flood is removed from the default
    /// flow. Only CFG/FEEDBACK, ENTROPY, and GRANULARITY are surfaced automatically;
    /// every other parameter must be opted into manually from the canvas.
    func autoGenerateExposedControls(for macroNode: MacroNode) {
        // Remove any existing exposed controls for this node or its internal nodes
        exposedControls.removeAll { control in
            control.nodeId == macroNode.id ||
            macroNode.internalGraph.nodes.keys.contains(control.nodeId)
        }

        var positionCounter = 0

        // 1. Expose MacroNode's own identity parameters (if any).
        for (paramId, value) in macroNode.parameters {
            guard let floatValue = value as? Float,
                  Self.isIdentityParameter(paramId) else { continue }
            let control = ExposedControl(
                id: UUID(),
                nodeId: macroNode.id,
                paramId: paramId,
                label: paramId.capitalized,
                controlType: inferControlType(for: paramId, value: value),
                range: inferRange(for: paramId),
                defaultValue: floatValue,
                midiCC: nil,
                position: positionCounter
            )
            exposedControls.append(control)
            positionCounter += 1
        }

        // 2. Expose internal identity parameters with musical labels.
        for (internalNodeId, node) in macroNode.internalGraph.nodes {
            guard !node.nodeType.contains("utility") else { continue }

            for (paramId, value) in node.parameters {
                guard let floatValue = value as? Float,
                      Self.isIdentityParameter(paramId) else { continue }

                let label = createMusicalLabel(nodeType: node.nodeType, paramId: paramId)

                let control = ExposedControl(
                    id: UUID(),
                    nodeId: internalNodeId,
                    paramId: paramId,
                    label: label,
                    controlType: inferControlType(for: paramId, value: value),
                    range: inferRange(for: paramId),
                    defaultValue: floatValue,
                    midiCC: nil,
                    position: positionCounter
                )
                exposedControls.append(control)
                positionCounter += 1
            }
        }

        objectWillChange.send()
    }

    /// Auto-generate exposed controls for the main graph.
    ///
    /// v2.0 Wave C: the all-floats flood is removed from the default flow. Flat
    /// graphs without macros now expose no controls by default; every parameter
    /// must be opted into manually from the canvas.
    func autoGenerateExposedControlsForMainGraph() {
        // No-op by design. Manual opt-in via GenericNodeCard's "Expose to Perform"
        // context menu is the only way to populate exposedControls on flat graphs.
        print("[NodeGraph] Auto-expose for main graph is disabled; use manual opt-in.")
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
        // ACE-Step / neural parameters (ACEStepInferenceNode, FeedbackLoopNode) --
        // explicit ranges so the auto-generated knob is actually usable instead
        // of silently falling through to the 0...1 default (guidanceScale's real
        // range is 3...20; a 0...1 knob can never reach unity gain at 10.0).
        case "guidanceScale":
            return LRConstants.cfgScaleRange
        case "feedback", "inputStrength", "entropy", "granularity":
            return 0.0...1.0
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
        triggerDebouncedSave()
    }

    /// Remove any edge touching `port` on `nodeId` (output or input side).
    func disconnectPort(nodeId: UUID, portId: String) {
        let toRemove = edges.values.filter { edge in
            (edge.sourceNodeId == nodeId && edge.sourcePortId == portId)
                || (edge.targetNodeId == nodeId && edge.targetPortId == portId)
        }
        for edge in toRemove {
            disconnectEdge(id: edge.id)
        }
    }

    /// Find the audio/control edge wired into a specific input port, if any.
    func edge(into nodeId: UUID, portId: String) -> GraphEdge? {
        edges.values.first { $0.targetNodeId == nodeId && $0.targetPortId == portId }
    }

    /// Find edges leaving a specific output port.
    func edges(from nodeId: UUID, portId: String) -> [GraphEdge] {
        edges.values.filter { $0.sourceNodeId == nodeId && $0.sourcePortId == portId }
    }

    /// Attempt to connect two ports; returns a human-readable error on failure.
    @discardableResult
    func connectPorts(
        from source: PatchPortRef,
        to target: PatchPortRef
    ) -> String? {
        guard source.direction == .output, target.direction == .input else {
            return "Cables run from output to input"
        }
        guard source.nodeId != target.nodeId else {
            return "Cannot connect a node to itself"
        }

        // Replace existing audio input (single-connection rule).
        if target.signalType == .audio, let existing = edge(into: target.nodeId, portId: target.portId) {
            disconnectEdge(id: existing.id)
        }

        let edge = GraphEdge(
            sourceNodeId: source.nodeId,
            sourcePortId: source.portId,
            targetNodeId: target.nodeId,
            targetPortId: target.portId,
            signalType: source.signalType
        )

        do {
            try connectEdge(edge)
            return nil
        } catch GraphError.invalidConnection(let message) {
            return message
        } catch {
            return error.localizedDescription
        }
    }
    
    // MARK: - Serialization

    func serialize() -> SerializedGraph {
        #if DEBUG
        let positions = nodes.values.map { ["id": $0.id.uuidString, "x": $0.x, "y": $0.y] }
        print("NodeGraph.serialize: nodeCount=\(nodes.count) edgeCount=\(edges.count) positions=\(positions)")
        #else
        print("NodeGraph.serialize: nodeCount=\(nodes.count) edgeCount=\(edges.count)")
        #endif

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
                params: params,
                bridge: aceBridge,
                audioInputBuffer: audioInputBuffer
            ) else {
                throw GraphError.unknownNodeType(serialized.nodeType)
            }
            node.name = serialized.displayName
            node.x = serialized.position.x
            node.y = serialized.position.y
            if let stageKind = serialized.stageKind {
                (node as? BaseGraphNode)?.stageKind = stageKind
            }
            if let macro = node as? MacroNode {
                macro.migrateStageKindFromMetadataIfNeeded()
            }
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

        wireNeuralNodes()
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
//
// Moved to `Graph/GraphSerialization.swift` for P3.13 (NodeGraph.swift
// vertedero cleanup). `SerializedGraph`, `SerializedNode`, `CodableValue`,
// and `GraphViewport` are plain top-level Codable value types with no
// NodeGraph private-state coupling, so they lift out with no API or
// behavior change.

// (Serialization type bodies — SerializedNode, CodableValue, GraphViewport —
//  now live in `Graph/GraphSerialization.swift`.)

// MARK: - Exposed Control / Macro Binding / Graph Errors
//
// Moved to `Graph/GraphSupportTypes.swift` for P3.13 (NodeGraph.swift
// vertedero cleanup). `ExposedControl`, `ControlWidget`, `MacroBinding`,
// `MacroTarget`, `ScalingCurve`, and `GraphError` are plain top-level
// Codable value types / error enum with no NodeGraph private-state
// coupling, so they lift out with no API or behavior change.

// MARK: - Node Factory
//
// Moved to `Graph/NodeFactory.swift` for P3.13 (NodeGraph.swift vertedero
// cleanup). `NodeFactory` is a caseless enum used as a namespace for the
// static `createNode` switch — it closes over no NodeGraph private state,
// so it lifts out with no API or behavior change. `NodeGraph.addNode` and
// `NodeGraph.deserialize(_:)` continue to call `NodeFactory.createNode(...)`
// unchanged.
