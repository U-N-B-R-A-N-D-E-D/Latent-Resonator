import Foundation
import QuartzCore

// MARK: - Control Graph Evaluator (Phase 2)
//
// Evaluates control-rate signals in the NodeGraph at ~60Hz.
// Handles:
// - Topological sorting of control nodes (evaluate dependencies first)
// - Evaluating each control node's outputs
// - Applying modulation values to target parameters via ModulationEngine
//
// Architecture notes:
// - Runs independently of audio thread (60Hz on main queue)
// - Only evaluates control nodes (agitation, peak, manual_control)
// - Audio nodes are ignored (audio flows through H19 path)

final class ControlGraphEvaluator {
    
    // MARK: - State
    
    private var lastEvaluationTime: TimeInterval = 0
    private let evaluationInterval: TimeInterval = 1.0 / 60.0  // 60Hz
    
    // MARK: - Timer Management
    
    private var evaluationTimer: Timer?
    weak var nodeGraph: NodeGraph?
    
    /// Callback for clients to receive notification after each evaluation cycle.
    /// Used by NeuralEngine to trigger RT snapshot updates on all lanes.
    var onEvaluationComplete: (() -> Void)?
    
    /// Start 60Hz evaluation timer.
    /// Thread-safe: must be called from main thread.
    func start() {
        stop()
        lastEvaluationTime = CACurrentMediaTime()
        
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: evaluationInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        
        // Add to common run loop modes for background operation
        if let timer = evaluationTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    /// Stop evaluation timer.
    func stop() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }
    
    /// Single evaluation tick at 60Hz.
    /// Evaluates control graph, applies modulation to target parameters, and notifies clients.
    private func tick() {
        guard let graph = nodeGraph else { return }
        
        let currentTime = CACurrentMediaTime()
        
        // 1. Evaluate all control nodes
        let outputs = evaluate(graph: graph, at: currentTime)
        
        // 2. Apply modulation to target parameters via control edges
        applyModulation(outputs: outputs, graph: graph)
        
        // 3. Notify clients (e.g., NeuralEngine to update RT snapshots)
        onEvaluationComplete?()
    }
    
    // MARK: - Evaluation
    
    /// Evaluate all control nodes in the graph and return their output values.
    /// Returns a map: nodeId → portId → Float value
    ///
    /// Thread safety: Must be called on main thread (accesses NodeGraph @Published properties).
    func evaluate(graph: NodeGraph, at time: TimeInterval) -> [UUID: [String: Float]] {
        let dt = time - lastEvaluationTime
        lastEvaluationTime = time
        
        // 1. Filter to control nodes only
        let controlNodes = graph.nodes.values.filter { node in
            node.category == .control
        }
        
        // 2. Topologically sort control nodes (evaluate dependencies first)
        let sortedNodeIds = topologicalSort(controlNodes: controlNodes, graph: graph)
        
        // 3. Evaluate each control node and collect outputs
        var outputs: [UUID: [String: Float]] = [:]
        
        for nodeId in sortedNodeIds {
            guard let node = graph.nodes[nodeId] else { continue }
            
            // Evaluate node's control outputs
            // Different node types have different evaluation logic
            if let agitationNode = node as? AgitationNode {
                let value = agitationNode.evaluate(at: time, dt: dt)
                outputs[nodeId] = ["out": value]
                
            } else if let peakNode = node as? PeakNode {
                let value = peakNode.evaluate(at: time, dt: dt)
                outputs[nodeId] = ["out": value]
                
            } else if let manualNode = node as? ManualControlNode {
                let value = manualNode.evaluate(at: time, dt: dt)
                outputs[nodeId] = ["out": value]
            }
        }
        
        // 4. Add MacroNode CV outputs (telemetry from audio analysis)
        // MacroNodes expose spectral analysis and level as CV for cross-modulation
        // v2.0: Telemetry is now sourced from analysis nodes in the internal graph
        for node in graph.nodes.values {
            if let macroNode = node as? MacroNode {
                // Get telemetry from macroNode parameters (set by analysis nodes)
                let level = macroNode.parameters["currentRMS"] as? Float ?? 0.0
                let centroid = macroNode.parameters["spectralCentroidNormalized"] as? Float ?? 0.0
                let flatness = macroNode.parameters["spectralFlatnessNormalized"] as? Float ?? 0.0
                outputs[macroNode.id] = [
                    "cv_level": level,
                    "cv_centroid": centroid,
                    "cv_flatness": flatness,
                    "cv_flux": 0.0,  // Reserved for future telemetry
                    "cv_crest": 0.0  // Reserved for future telemetry
                ]
            }
        }
        
        return outputs
    }
    
    // MARK: - Topological Sort
    
    /// Topologically sort control nodes to ensure dependencies are evaluated first.
    /// Uses Kahn's algorithm (BFS-based) to detect and handle cycles.
    private func topologicalSort(controlNodes: [any GraphNode], graph: NodeGraph) -> [UUID] {
        let controlNodeIds = Set(controlNodes.map { $0.id })
        
        // Build adjacency list and in-degree map (only for control nodes)
        var inDegree: [UUID: Int] = [:]
        var adjacencyList: [UUID: [UUID]] = [:]
        
        for nodeId in controlNodeIds {
            inDegree[nodeId] = 0
            adjacencyList[nodeId] = []
        }
        
        // Count in-degrees and build adjacency list
        for edge in graph.edges.values {
            // Only consider edges between control nodes
            guard controlNodeIds.contains(edge.sourceNodeId),
                  controlNodeIds.contains(edge.targetNodeId) else {
                continue
            }
            
            inDegree[edge.targetNodeId, default: 0] += 1
            adjacencyList[edge.sourceNodeId, default: []].append(edge.targetNodeId)
        }
        
        // Kahn's algorithm: start with nodes that have no dependencies
        var queue = Array(controlNodeIds.filter { inDegree[$0] == 0 })
        var sorted: [UUID] = []
        
        while !queue.isEmpty {
            let nodeId = queue.removeFirst()
            sorted.append(nodeId)
            
            // Reduce in-degree for neighbors
            for neighborId in adjacencyList[nodeId, default: []] {
                inDegree[neighborId, default: 0] -= 1
                if inDegree[neighborId] == 0 {
                    queue.append(neighborId)
                }
            }
        }
        
        // If sorted count doesn't match input, there was a cycle
        // In this case, just return nodes in arbitrary order (cyclic control graphs are valid in modular synths)
        if sorted.count != controlNodeIds.count {
            print("ControlGraphEvaluator: Cycle detected in control graph, using arbitrary order")
            return Array(controlNodeIds)
        }
        
        return sorted
    }
    
    // MARK: - Modulation Application
    
    /// Apply control values to target parameters via NodeGraph.
    /// Implements Phase 2: CV routing for cross-macro modulation.
    ///
    /// v2.0 Architecture: Control edges route from source node outputs to target 
    /// node parameters via NodeGraph.setParameter(). This maintains NodeGraph as
    /// the single source of truth. RT snapshots are updated separately at 60Hz
    /// to provide lock-free audio thread access.
    ///
    /// - Parameters:
    ///   - outputs: Map of nodeId → portId → value from evaluate()
    ///   - graph: The NodeGraph containing edges (source of truth for parameters)
    func applyModulation(
        outputs: [UUID: [String: Float]],
        graph: NodeGraph
    ) {
        // For each control edge, apply the source node's output to the target parameter
        for edge in graph.edges.values {
            guard edge.signalType == .control else { continue }
            
            // Get source node's output value
            guard let sourceOutputs = outputs[edge.sourceNodeId],
                  let sourceValue = sourceOutputs[edge.sourcePortId] else {
                continue
            }
            
            // Get target parameter key from port ID (strip _cv suffix if present)
            let paramKey = edge.targetPortId.replacingOccurrences(of: "_cv", with: "")
            
            // Apply modulation additively to existing parameter value via NodeGraph
            // This ensures parameter change notifications are emitted and RT snapshot will pick up new value
            if let currentValue = graph.getParameter(nodeId: edge.targetNodeId, key: paramKey) {
                let modulatedValue = currentValue + sourceValue
                graph.setParameter(nodeId: edge.targetNodeId, key: paramKey, value: modulatedValue)
            } else {
                // Parameter doesn't exist yet, set directly
                graph.setParameter(nodeId: edge.targetNodeId, key: paramKey, value: sourceValue)
            }
        }
    }
}
