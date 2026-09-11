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

    /// Last `clock_in` value seen for each `MarkovSequencerNode` — used for
    /// rising-edge clock detection. Pre-allocated on the main thread; no
    /// audio-thread access.
    private var lastMarkovClock: [UUID: Float] = [:]

    /// Last trigger values seen for each `GestureRecorderNode` gate input.
    private var lastGestureTrigger: [UUID: [String: Float]] = [:]

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
    
    /// Evaluate all control/analysis nodes in the graph and return their
    /// output values. Also routes text signals (`prompt_out` → `prompt_in`)
    /// into the target `ACEStepInferenceNode` on the main thread.
    ///
    /// Returns a map: nodeId → portId → Float value
    ///
    /// Thread safety: Must be called on main thread (accesses NodeGraph @Published properties).
    func evaluate(graph: NodeGraph, at time: TimeInterval) -> [UUID: [String: Float]] {
        let dt = time - lastEvaluationTime
        lastEvaluationTime = time

        // 1. Filter to control + analysis nodes. Analysis nodes (e.g.
        // SpectralAnalyzerNode) expose control-rate outputs that must be
        // topologically sorted alongside other control nodes.
        let controlNodes = graph.nodes.values.filter { node in
            node.category == .control || node.category == .analysis
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

            } else if let metaNode = node as? MetaParameterNode {
                let value = metaNode.evaluate(dt: dt)
                outputs[nodeId] = ["out": value]

            } else if let markovNode = node as? MarkovSequencerNode {
                evaluateMarkov(markovNode, at: time, outputs: outputs, graph: graph)
                outputs[nodeId] = [
                    "value_out": markovNode.evaluateControl(portId: "value_out", at: time),
                    "gate_out": markovNode.evaluateControl(portId: "gate_out", at: time),
                    "prompt_out": 0.0
                ]

            } else if let gestureNode = node as? GestureRecorderNode {
                evaluateGesture(gestureNode, outputs: outputs, graph: graph, at: time)
                outputs[nodeId] = [
                    "x_out": gestureNode.evaluateControl(portId: "x_out", at: time),
                    "y_out": gestureNode.evaluateControl(portId: "y_out", at: time),
                    "pressure_out": gestureNode.evaluateControl(portId: "pressure_out", at: time),
                    "gate_out": gestureNode.evaluateControl(portId: "gate_out", at: time)
                ]

            } else if let analyzerNode = node as? SpectralAnalyzerNode {
                outputs[nodeId] = [
                    "centroid": analyzerNode.evaluateControl(portId: "centroid", at: time),
                    "flatness": analyzerNode.evaluateControl(portId: "flatness", at: time),
                    "flux": analyzerNode.evaluateControl(portId: "flux", at: time)
                ]
            }
        }

        // 4. Route text signals: prompt_out / text_out → prompt_in on
        // ACEStepInferenceNode. Kept on the main/evaluator thread — never the
        // audio thread.
        routeTextSignals(graph: graph)

        // 5. Add MacroNode CV outputs (telemetry from audio analysis)
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

    // MARK: - Per-Node Control Evaluation

    /// Rising-edge clock evaluation for `MarkovSequencerNode`.
    /// Reads `clock_in`, `reset_in`, and `temp_cv` from `outputs`/`graph` and
    /// drives the node's state machine on the main thread.
    private func evaluateMarkov(
        _ markov: MarkovSequencerNode,
        at time: TimeInterval,
        outputs: [UUID: [String: Float]],
        graph: NodeGraph
    ) {
        let nodeId = markov.id
        let clockValue = valueForInput(into: nodeId, portId: "clock_in", outputs: outputs, graph: graph)
        let lastClock = lastMarkovClock[nodeId] ?? 0.0

        if clockValue > 0.5 && lastClock <= 0.5 {
            let tempCV = valueForInput(into: nodeId, portId: "temp_cv", outputs: outputs, graph: graph)
            markov.onClockTrigger(currentTime: time, tempCV: max(tempCV, 0.0))
        }

        let resetValue = valueForInput(into: nodeId, portId: "reset_in", outputs: outputs, graph: graph)
        if resetValue > 0.5 {
            markov.onResetTrigger()
        }

        lastMarkovClock[nodeId] = clockValue
    }

    /// Rising-edge trigger evaluation for `GestureRecorderNode`.
    /// Maps `record_trig`, `play_trig`, and `stop_trig` to the node's
    /// transport methods and captures the current input point while recording
    /// at the 60 Hz control rate.
    private func evaluateGesture(
        _ gesture: GestureRecorderNode,
        outputs: [UUID: [String: Float]],
        graph: NodeGraph,
        at time: TimeInterval
    ) {
        let nodeId = gesture.id
        var last = lastGestureTrigger[nodeId] ?? [:]

        for portId in ["record_trig", "play_trig", "stop_trig"] {
            let value = valueForInput(into: nodeId, portId: portId, outputs: outputs, graph: graph)
            let lastValue = last[portId] ?? 0.0
            if value > 0.5 && lastValue <= 0.5 {
                gesture.onGate(portId: portId, trigger: true)
            }
            last[portId] = value
        }

        lastGestureTrigger[nodeId] = last

        // Capture the current gesture point at control rate while recording.
        if gesture.state == .recording {
            gesture.capturePoint(at: time)
        }
    }

    /// Read the current value of a control/gate/trigger input port, if any.
    /// Returns `0.0` when the port is unconnected or the source has no output.
    private func valueForInput(
        into nodeId: UUID,
        portId: String,
        outputs: [UUID: [String: Float]],
        graph: NodeGraph
    ) -> Float {
        guard let edge = graph.edge(into: nodeId, portId: portId),
              edge.signalType == .control || edge.signalType == .gate || edge.signalType == .trigger else {
            return 0.0
        }
        return outputs[edge.sourceNodeId]?[edge.sourcePortId] ?? 0.0
    }

    // MARK: - Text Signal Routing

    /// Route `prompt_out` / `text_out` control edges into `prompt_in` inputs on
    /// `ACEStepInferenceNode`. Runs on the evaluator thread, never the audio thread.
    private func routeTextSignals(graph: NodeGraph) {
        for edge in graph.edges.values where edge.targetPortId == "prompt_in" {
            guard let target = graph.nodes[edge.targetNodeId] as? ACEStepInferenceNode else { continue }
            guard let source = graph.nodes[edge.sourceNodeId] else { continue }

            let text: String? = {
                if let markov = source as? MarkovSequencerNode {
                    return markov.evaluateText(portId: edge.sourcePortId)
                } else if let bank = source as? PromptBankNode {
                    return bank.evaluateText(portId: edge.sourcePortId)
                } else if let engine = source as? PromptEngineNode {
                    return engine.evaluateText()
                }
                return nil
            }()

            if let text = text, !text.isEmpty {
                target.prompt = text
            }
        }
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

            guard let sourceOutputs = outputs[edge.sourceNodeId],
                  let sourceValue = sourceOutputs[edge.sourcePortId] else {
                continue
            }

            let paramKey = edge.targetPortId.replacingOccurrences(of: "_cv", with: "")
            let baseKey = "cvBase_\(paramKey)"

            if graph.getParameterValue(nodeId: edge.targetNodeId, key: baseKey) == nil {
                let current = graph.getParameter(nodeId: edge.targetNodeId, key: paramKey) ?? 0
                graph.setParameter(nodeId: edge.targetNodeId, key: baseKey, value: current)
            }

            let base = graph.getParameter(nodeId: edge.targetNodeId, key: baseKey)
                ?? graph.getParameter(nodeId: edge.targetNodeId, key: paramKey)
                ?? 0
            
            let depth: Float
            if paramKey == "frequency" {
                depth = LRConstants.controlFrequencyCVDepth
            } else {
                depth = LRConstants.controlCVDepth
            }
            
            let modulated = base + sourceValue * depth
            graph.setParameter(nodeId: edge.targetNodeId, key: paramKey, value: modulated)
        }
    }
}
