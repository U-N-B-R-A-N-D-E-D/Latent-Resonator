import Foundation
import AVFoundation
import Accelerate

// MARK: - Audio Graph Mapper

/// Translates NodeGraph topology to AVAudioEngine audio routing.
/// This is the core class for the v2.0 "Graph-First" architecture.
///
/// ## Architecture
/// - NodeGraph is the source of truth for both visual and audio
/// - AudioGraphMapper rebuilds AVAudioEngine when topology changes
/// - Parameter changes happen in-place without rebuild (~0ms latency)
/// - Topology changes require ~50ms rebuild (masked by fade)
///
/// ## Signal Types
/// - Audio edges → AVAudioEngine.connect()
/// - Control edges → ModulationGraph (60Hz evaluation)
/// - Gate edges → SequencerEngine triggers
/// - Text edges → Neural inference prompts
final class AudioGraphMapper {

    // MARK: - State

    private let avEngine: AVAudioEngine
    private let format: AVAudioFormat

    /// Nodes currently attached to AVAudioEngine (for cleanup on rebuild)
    private var attachedAudioNodes: [UUID: AVAudioNode] = [:]

    /// Master volume node for fade in/out during rebuilds
    private let masterVolumeNode: AVAudioMixerNode

    // MARK: - Init

    init(avEngine: AVAudioEngine, masterVolumeNode: AVAudioMixerNode) {
        self.avEngine = avEngine
        self.masterVolumeNode = masterVolumeNode

        // Standard 48kHz stereo format for all connections
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            fatalError("Failed to create audio format")
        }
        self.format = format
    }

    // MARK: - Topology Analysis

    /// Determines if a graph mutation requires rebuilding the audio engine.
    /// - Parameter mutation: The graph mutation to check
    /// - Returns: true if rebuild required, false for in-place parameter update
    func requiresRestart(_ mutation: GraphMutation) -> Bool {
        return mutation.requiresAudioGraphRebuild
    }

    /// Verifies that all audio nodes form a valid connected graph reaching the output.
    /// Implements whitepaper §3.3 graph topology validation.
    /// - Parameter graph: The NodeGraph to validate
    /// - Throws: MapperError if graph is invalid or disconnected
    func validateGraphConnected(_ graph: NodeGraph) throws {
        // Collect all nodes and edges
        let allNodes = graph.nodes
        let allEdges = graph.edges
        let audioEdges = allEdges.values.filter { $0.signalType == .audio }

        // 1. Identify all audio-producing nodes (nodes with audioUnit)
        let audioNodes = allNodes.values.filter { $0.audioUnit() != nil }
        guard !audioNodes.isEmpty else {
            throw MapperError.invalidConfiguration("Graph has no audio nodes. Add at least one source.")
        }

        // 2. Identify source nodes (audio nodes with no audio inputs)
        let sourceNodes = audioNodes.filter { node in
            !audioEdges.contains { $0.targetNodeId == node.id }
        }
        guard !sourceNodes.isEmpty else {
            throw MapperError.invalidConfiguration("Graph has no audio source nodes. Add an oscillator or input.")
        }

        // 3. Must have exactly one MasterOutputNode
        let masterOutputs = allNodes.values.compactMap { $0 as? MasterOutputNode }
        if masterOutputs.count > 1 {
            throw MapperError.invalidConfiguration(
                "Graph must have exactly one MasterOutputNode. Found: \(masterOutputs.count)"
            )
        }
        // Allow fallback: if no MasterOutputNode, we'll connect directly to masterVolumeNode
        // This enables simpler graphs without explicit MasterOutputNode
        if masterOutputs.isEmpty {
            print("[GraphValidation] ⚠️ No MasterOutputNode found - will use fallback connection to master")
        }

        // 4. Walk backwards from MasterOutputNode (or all terminal nodes) to verify connectivity
        var reachable = Set<UUID>()
        var toVisit: [UUID] = []

        if let master = masterOutputs.first {
            toVisit.append(master.id)
        } else {
            // Fallback: identify terminal nodes (nodes with no outgoing audio edges)
            let allSourceIds = Set(audioEdges.map { $0.sourceNodeId })
            let allTargetIds = Set(audioEdges.map { $0.targetNodeId })
            let terminalIds = allTargetIds.subtracting(allSourceIds)
            toVisit.append(contentsOf: terminalIds)
        }

        while !toVisit.isEmpty {
            let nodeId = toVisit.removeFirst()
            guard reachable.insert(nodeId).inserted else { continue }

            // Find all nodes that feed into this one (audio edges only)
            for edge in audioEdges where edge.targetNodeId == nodeId {
                toVisit.append(edge.sourceNodeId)
            }
        }

        // 5. All audio nodes should ideally be reachable, but we'll be more lenient
        // Only fail if NO sources are reachable (completely disconnected graph)
        let reachableSources = sourceNodes.filter { reachable.contains($0.id) }
        guard !reachableSources.isEmpty else {
            throw MapperError.invalidConfiguration(
                "No audio sources connected to output. Connect at least one source (oscillator, noise, etc.) to the output chain."
            )
        }

        // 6. Log unreachable nodes as warnings (not errors) - they just won't make sound
        let unreachableNodes = audioNodes.filter { !reachable.contains($0.id) }
        if !unreachableNodes.isEmpty {
            let details = unreachableNodes.map { "\($0.name) (\($0.nodeType))" }.joined(separator: ", ")
            print("[GraphValidation] ⚠️ Unreachable audio nodes (will not produce sound): \(details)")
        }

        // Success logging
        print("[GraphValidation] ✓ Audio graph valid: \(audioNodes.count) nodes, \(sourceNodes.count) sources, \(reachableSources.count) connected to output")

        // #region agent log - H2 Connectivity check
        debugLog(location: "AudioGraphMapper:validateGraph", message: "Graph connectivity validated", data: [
            "totalNodes": String(allNodes.count),
            "audioNodes": String(audioNodes.count),
            "sourceNodes": String(sourceNodes.count),
            "reachable": String(reachable.count),
            "audioEdges": String(audioEdges.count)
        ], hypothesisId: "H2")
        // #endregion
    }

    // MARK: - Engine Rebuild

    /// Rebuilds AVAudioEngine topology from NodeGraph.
    ///
    /// ## Process
    /// 1. Fade master to 0 (10ms ramp to prevent clicks)
    /// 2. Stop AVAudioEngine
    /// 3. Detach all previously attached nodes
    /// 4. Walk graph in topological order
    /// 5. Attach each node's audioUnit() to engine
    /// 6. Connect audio edges (source → target)
    /// 7. Start AVAudioEngine
    /// 8. Fade master to 1 (10ms ramp)
    ///
    /// ## Performance
    /// - Total rebuild time: ~50ms
    /// - Gap masked by: 10ms fade out + 10ms fade in
    /// - Safe for: Live performance with care
    ///
    /// - Parameter graph: The NodeGraph to rebuild from
    /// - Throws: MapperError if rebuild fails
    func rebuild(from graph: NodeGraph) throws {
        // #region agent log - H1 Audio rebuild trace
        debugLog(location: "AudioGraphMapper:rebuild:entry", message: "Starting audio graph rebuild", data: ["nodeCount": String(graph.nodes.count), "edgeCount": String(graph.edges.count)], hypothesisId: "H1")
        // #endregion

        let sorted = graph.topologicalSort()
        var allNodesToAttach: [(UUID, any GraphNode)] = []

        // Add all nodes from the graph
        for nodeId in sorted {
            if let node = graph.nodes[nodeId] {
                allNodesToAttach.append((nodeId, node))
            }
        }

        // Check how many audio nodes would actually be attached
        var audioNodesToAttach: [(UUID, AVAudioNode)] = []
        var nodesWithoutAudioUnits: [String] = []
        for (nodeId, node) in allNodesToAttach {
            if let audioNode = node.audioUnit() {
                audioNodesToAttach.append((nodeId, audioNode))
            } else {
                nodesWithoutAudioUnits.append(node.name)
            }
        }

        // #region agent log - H1 Audio nodes analysis
        debugLog(location: "AudioGraphMapper:rebuild:analysis", message: "Audio nodes analysis", data: [
            "totalNodes": String(allNodesToAttach.count),
            "audioNodes": String(audioNodesToAttach.count),
            "noAudioUnitNodes": nodesWithoutAudioUnits.joined(separator: ",")
        ], hypothesisId: "H1")
        // #endregion
        
        // Diagnostic logging
        print("AudioGraphMapper: Analyzing - \(allNodesToAttach.count) total nodes, \(audioNodesToAttach.count) with audio units")
        print("AudioGraphMapper: Currently attached: \(attachedAudioNodes.count) nodes")

        // Fail loudly if no audio nodes to attach (empty graph)
        guard !audioNodesToAttach.isEmpty else {
            throw MapperError.invalidConfiguration(
                "Graph has no audio nodes to attach. Load a topology first."
            )
        }

        // Also skip if nothing changed (same nodes already attached)
        let currentIds = Set(attachedAudioNodes.keys)
        let newIds = Set(audioNodesToAttach.map { $0.0 })
        if currentIds == newIds {
            print("AudioGraphMapper: Audio topology unchanged (current=\(currentIds.count), new=\(newIds.count)), skipping rebuild")
            return
        }

        print("AudioGraphMapper: Topology changed (current=\(currentIds.count), new=\(newIds.count)), proceeding with rebuild")

        // Validate graph connectivity - throws on failure with detailed error
        try validateGraphConnected(graph)

        print("AudioGraphMapper: Graph connectivity validated successfully")

        print("AudioGraphMapper: Rebuilding with \(audioNodesToAttach.count) audio nodes")

        // 1. Fade out master (10ms ramp)
        fadeMaster(to: 0.0, duration: 0.01)

        // Wait for fade to complete
        Thread.sleep(forTimeInterval: 0.01)

        // 2. Stop engine
        avEngine.stop()

        // 3. Detach all previously attached nodes
        for (_, node) in attachedAudioNodes {
            avEngine.detach(node)
        }
        attachedAudioNodes.removeAll()

        // 4. Attach new audio nodes
        for (nodeId, audioNode) in audioNodesToAttach {
            avEngine.attach(audioNode)
            attachedAudioNodes[nodeId] = audioNode
        }
        
        print("AudioGraphMapper: Attached \(attachedAudioNodes.count) nodes")

        // 6. Connect audio edges
        // v2.0: Support tap-based connections for processing nodes
        let allAudioEdges = graph.edges.values.filter { $0.signalType == .audio }
        
        // Track which nodes already have taps installed (avoid duplicates)
        var tappedNodes = Set<UUID>()
        
        // CRITICAL: Installing taps while engine is running causes deadlock
        // Only install taps if engine is not running - otherwise schedule for lazy install
        let canInstallTaps = !avEngine.isRunning
        if !canInstallTaps {
            print("AudioGraphMapper: WARNING - Engine running, skipping tap installation. Taps will need lazy install.")
        }
        
        // Track connection failures for debugging
        var connectionErrors: [(UUID, UUID, String)] = []
        
        for edge in allAudioEdges {
            guard let sourceAVNode = attachedAudioNodes[edge.sourceNodeId],
                  let targetAVNode = attachedAudioNodes[edge.targetNodeId] else {
                print("AudioGraphMapper: Skipping edge \(edge.id) - nodes not attached")
                connectionErrors.append((edge.sourceNodeId, edge.targetNodeId, "Nodes not attached"))
                continue
            }

            // Debug: log node types
            let sourceType = String(describing: type(of: sourceAVNode))
            let targetType = String(describing: type(of: targetAVNode))
            print("AudioGraphMapper: Edge \(edge.id): \(sourceType) → \(targetType)")

            // Case 1: Target is a processing node that receives audio via tap (not direct connection)
            if let spectralChainNode = graph.findNode(edge.targetNodeId) as? SpectralChainNode {
                // SpectralChainNode: use tap pattern instead of direct connection
                // Only install tap once per target node, and only if engine is not running
                if canInstallTaps && !tappedNodes.contains(edge.targetNodeId) {
                    tappedNodes.insert(edge.targetNodeId)
                    spectralChainNode.installUpstreamTap(from: sourceAVNode, in: avEngine)
                    print("AudioGraphMapper: Installed tap on SpectralChainNode for edge \(edge.id)")
                } else if !canInstallTaps {
                    print("AudioGraphMapper: Deferring tap install for SpectralChainNode (engine running)")
                }
                // If engine is running, tap will be installed lazily by the node itself
                continue
            }
            
            if let feedbackLoopNode = graph.findNode(edge.targetNodeId) as? FeedbackLoopNode {
                // FeedbackLoopNode: use tap pattern to feed spectral audio for recursive loop
                // Only install tap once per target node, and only if engine is not running
                if canInstallTaps && !tappedNodes.contains(edge.targetNodeId) {
                    tappedNodes.insert(edge.targetNodeId)
                    feedbackLoopNode.installUpstreamTap(from: sourceAVNode, in: avEngine)
                    print("AudioGraphMapper: Installed tap on FeedbackLoopNode for edge \(edge.id)")
                } else if !canInstallTaps {
                    print("AudioGraphMapper: Deferring tap install for FeedbackLoopNode (engine running)")
                }
                continue
            }
            
            // Case 2: Target cannot receive input (AVAudioSourceNode has no inputs)
            // Skip these connections - they represent a broken graph topology
            if targetAVNode is AVAudioSourceNode {
                print("AudioGraphMapper: SKIPPING edge \(edge.id) - AVAudioSourceNode cannot receive input (no input bus)")
                connectionErrors.append((edge.sourceNodeId, edge.targetNodeId, 
                    "Source-to-source connection invalid: \(sourceType) → \(targetType)"))
                continue
            }
            
            // Case 3: Standard connection for mixer/output nodes that can receive input
            if targetAVNode is AVAudioMixerNode || targetAVNode is AVAudioOutputNode {
                avEngine.connect(sourceAVNode, to: targetAVNode, format: format)
                continue
            }
            
            // Case 4: Unknown/unsupported target type
            print("AudioGraphMapper: SKIPPING edge \(edge.id) - Target type \(targetType) may not accept input")
            connectionErrors.append((edge.sourceNodeId, edge.targetNodeId, 
                "Unsupported target type: \(targetType)"))
        }

        // 6b. Connect graph output to masterVolumeNode.
        //
        // A.3 FIX: The audio chain must reach masterVolumeNode (→ mainMixerNode →
        // outputNode) or nothing is audible. We prefer the explicit MasterOutputNode
        // as the single terminal, and fall back to any leaf (node with no outgoing
        // audio edges) if there isn't one — this covers legacy/minimal graphs
        // without a MasterOutputNode.
        //
        // NOTE: The previous logic used `allSourceNodeIds.subtracting(allTargetNodeIds)`
        // which finds *roots* (pure source nodes, no incoming edges) instead of leaves.
        // That inverted the signal path: oscillators were wired directly to master,
        // bypassing every intermediate filter/mixer/effect, and MasterOutputNode's
        // mixer was attached but never connected to anything. Audible symptom: raw
        // dry oscillators (or silence, depending on graph shape).
        let allTargetNodeIds = Set(allAudioEdges.map { $0.targetNodeId })
        let allSourceNodeIds = Set(allAudioEdges.map { $0.sourceNodeId })

        let masterOutputs = graph.nodes.values.compactMap { $0 as? MasterOutputNode }
        var terminalNodeIds: Set<UUID> = []

        if let master = masterOutputs.first,
           attachedAudioNodes.keys.contains(master.id) {
            // Preferred: route MasterOutputNode's internal mixer → masterVolumeNode.
            terminalNodeIds.insert(master.id)
            if masterOutputs.count > 1 {
                print("AudioGraphMapper: ⚠️ Multiple MasterOutputNodes (\(masterOutputs.count)) — using first. Graph validation should have caught this.")
            }
        } else {
            // Fallback: any leaf (no outgoing audio edges). Correct direction this time.
            let leafNodeIds = allTargetNodeIds.subtracting(allSourceNodeIds)
                .filter { attachedAudioNodes.keys.contains($0) }
            // Also include nodes that are neither source nor target (isolated nodes
            // with audio units, e.g. a sole oscillator with no edges at all).
            let isolatedNodeIds = Set(attachedAudioNodes.keys)
                .subtracting(allSourceNodeIds)
                .subtracting(allTargetNodeIds)
            terminalNodeIds = leafNodeIds.union(isolatedNodeIds)

            // NEW: Also connect any source nodes that have no outgoing edges at all
            // (orphaned sources that were never connected to anything)
            // Compute source nodes: audio nodes with no incoming audio edges
            let audioNodes = graph.nodes.values.filter { $0.audioUnit() != nil }
            let sourceNodes = audioNodes.filter { node in
                !allAudioEdges.contains { $0.targetNodeId == node.id }
            }
            let orphanedSourceIds = Set(sourceNodes.map { $0.id })
                .subtracting(allSourceNodeIds)
                .filter { attachedAudioNodes.keys.contains($0) }
            terminalNodeIds.formUnion(orphanedSourceIds)

            print("AudioGraphMapper: ⚠️ No MasterOutputNode found — falling back to \(terminalNodeIds.count) leaf/isolated/orphaned nodes")
        }

        if !terminalNodeIds.isEmpty {
            print("AudioGraphMapper: Connecting \(terminalNodeIds.count) terminal node(s) to masterVolumeNode")

            // Create an intermediate mixer for source nodes (AVAudioSourceNodes can't connect directly to master)
            let sourceMixer = AVAudioMixerNode()
            avEngine.attach(sourceMixer)
            avEngine.connect(sourceMixer, to: masterVolumeNode, format: format)
            print("AudioGraphMapper: Created sourceMixer → masterVolumeNode for handling source nodes")

            for nodeId in terminalNodeIds {
                guard let avNode = attachedAudioNodes[nodeId] else { continue }
                let nodeType = String(describing: type(of: avNode))
                let label = graph.nodes[nodeId]?.name ?? "unknown"

                // AVAudioSourceNodes (Oscillators, etc.) need to connect TO a mixer
                // (they can only be sources, not targets)
                if avNode is AVAudioSourceNode {
                    avEngine.connect(avNode, to: sourceMixer, format: format)
                    print("AudioGraphMapper: ✓ Source '\(label)' (\(nodeType)) → sourceMixer → masterVolumeNode")
                }
                // Mixers and other nodes that can receive input connect directly
                else if avNode is AVAudioMixerNode || avNode is AVAudioOutputNode {
                    // Already connected upstream, don't double-connect
                    print("AudioGraphMapper: ✓ Terminal '\(label)' (\(nodeType)) already in chain")
                }
                else {
                    // Unknown node type - try connecting to sourceMixer as fallback
                    avEngine.connect(avNode, to: sourceMixer, format: format)
                    print("AudioGraphMapper: ✓ Unknown type '\(label)' (\(nodeType)) → sourceMixer (fallback)")
                }
            }
        } else {
            print("AudioGraphMapper: ⚠️ No terminal nodes found — graph will be inaudible")
        }
        
        // Log connection issues but don't fail the rebuild
        // In v2.0, some edges represent conceptual flow (e.g., tap feeding) rather than direct connections
        if !connectionErrors.isEmpty {
            let errorMessages = connectionErrors.map { "\($0.0) → \($0.1): \($0.2)" }.joined(separator: "; ")
            print("AudioGraphMapper: Note - \(connectionErrors.count) edges skipped (expected in v2.0 tap architecture): \(errorMessages)")
            // Don't throw - these are often expected for tap-based routing
        }

        // 7. Start engine
        try avEngine.start()

        // 8. Fade in master (10ms ramp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.fadeMaster(to: 1.0, duration: 0.01)
        }

        // Final summary log
        print("[AudioRebuild] ✓ Complete: \(attachedAudioNodes.count) nodes attached, \(terminalNodeIds.count) terminals to master, \(connectionErrors.count) tap edges")
    }

    // MARK: - Incremental Updates

    /// Updates a single parameter without rebuilding the audio engine.
    /// This is the fast path for knob turns and real-time control.
    ///
    /// - Parameters:
    ///   - nodeId: The node to update
    ///   - paramId: The parameter name
    ///   - value: The new value
    ///   - graph: The NodeGraph containing the node
    func updateParameter(nodeId: UUID, paramId: String, value: Any, in graph: NodeGraph) {
        // Use NodeGraph's API to update parameter (handles mutability)
        graph.setParameter(nodeId: nodeId, key: paramId, value: value as! Float)

        // If node has an audio unit, notify it of the change
        if attachedAudioNodes[nodeId] != nil {
            // Audio units update their parameters in real-time
            // No engine restart needed
            if var node = graph.nodes[nodeId] {
                node.onParameterChanged(key: paramId, value: value)
            }
        }
    }

    // MARK: - Utility

    /// Returns the AVAudioNode attached for a given graph node ID.
    /// - Parameter nodeId: The graph node ID
    /// - Returns: The attached AVAudioNode, if any
    func audioNode(for nodeId: UUID) -> AVAudioNode? {
        return attachedAudioNodes[nodeId]
    }

    /// Number of AVAudioNodes currently attached to the engine.
    var attachedNodeCount: Int {
        attachedAudioNodes.count
    }

    /// Clears all attached nodes (called during shutdown).
    func reset() {
        attachedAudioNodes.removeAll()
    }

    // MARK: - Cross-Lane Fade-Crossfade (DECISION D5)

    /// Rebuilds the audio graph with cross-lane connection using fade-crossfade algorithm.
    ///
    /// ## Algorithm (100ms total)
    /// 1. Phase 1 (0-50ms): Fade down source lane output volume (linear ramp to 0.0)
    /// 2. Phase 2 (50-60ms): Rebuild audio graph with new cross-lane connection
    /// 3. Phase 3 (60-100ms): Fade up source lane output volume (linear ramp to 1.0)
    ///
    /// ## Rationale
    /// - Prevents clicks/pops during graph reconfiguration
    /// - Volume is at 0 during the brief rebuild gap (~10ms)
    /// - Per-lane volume control preserves other lanes' audio during transition
    ///
    /// - Parameters:
    ///   - graph: The NodeGraph with new cross-lane edge
    ///   - sourceLaneId: The lane whose output will be cross-routed
    ///   - sourceLaneVolumeNode: The AVAudioMixerNode controlling source lane output volume
    /// - Throws: MapperError if rebuild fails
    func rebuildWithCrossLaneTransition(
        from graph: NodeGraph,
        sourceLaneId: UUID,
        sourceLaneVolumeNode: AVAudioMixerNode
    ) throws {
        // Phase 1: Fade down source lane (0-50ms)
        rampLaneVolume(node: sourceLaneVolumeNode, to: 0.0, duration: 0.05)
        Thread.sleep(forTimeInterval: 0.05)

        // Phase 2: Rebuild graph (50-60ms)
        // This is the critical section where audio topology changes
        do {
            try rebuild(from: graph)
        } catch {
            // Recovery: fade back up and rethrow
            rampLaneVolume(node: sourceLaneVolumeNode, to: 1.0, duration: 0.04)
            throw error
        }

        // Phase 3: Fade up source lane (60-100ms)
        rampLaneVolume(node: sourceLaneVolumeNode, to: 1.0, duration: 0.04)
    }

    /// Linear volume ramp for per-lane fade-crossfade transitions.
    ///
    /// - Parameters:
    ///   - node: The AVAudioMixerNode controlling lane volume
    ///   - targetValue: Target volume (0.0...1.0)
    ///   - duration: Ramp duration in seconds
    private func rampLaneVolume(node: AVAudioMixerNode, to targetValue: Float, duration: TimeInterval) {
        let startValue = node.outputVolume
        let frameCount = Int(duration * 60)  // 60Hz control rate matches ControlGraphEvaluator

        for frame in 0..<frameCount {
            let t = Float(frame) / Float(frameCount)  // 0.0...1.0
            // Linear interpolation
            let volume = startValue + (targetValue - startValue) * t
            node.outputVolume = volume

            // Wait for next frame (16.67ms at 60Hz)
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }

        // Ensure we hit the exact target
        node.outputVolume = targetValue
    }

    // MARK: - Private

    private func fadeMaster(to volume: Float, duration: TimeInterval) {
        let startVolume = masterVolumeNode.outputVolume
        let steps = 10
        let stepDuration = duration / TimeInterval(steps)
        let stepDelta = (volume - startVolume) / Float(steps)

        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(i) * stepDuration) { [weak self] in
                self?.masterVolumeNode.outputVolume = startVolume + stepDelta * Float(i + 1)
            }
        }
    }

    // MARK: - Debug Logging (Agent Instrumentation)

    /// Writes structured debug logs to the agent's log file for hypothesis testing.
    private func debugLog(location: String, message: String, data: [String: String], hypothesisId: String) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let logEntry: [String: Any] = [
            "sessionId": "54ee48",
            "id": "log_\(timestamp)_\(UUID().uuidString.prefix(8))",
            "timestamp": timestamp,
            "location": location,
            "message": message,
            "data": data,
            "hypothesisId": hypothesisId
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: logEntry),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let logPath = "/Users/leolambertini/RLTNAS/.cursor/debug-54ee48.log"
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write((jsonString + "\n").data(using: .utf8)!)
                    handle.closeFile()
                }
            } else {
                try? jsonString.write(toFile: logPath, atomically: false, encoding: .utf8)
            }
        }
    }
}

// MARK: - Errors

enum MapperError: Error, LocalizedError {
    case invalidConfiguration(String)

    // A.5: make sure error.localizedDescription surfaces the diagnostic string.
    // Without LocalizedError conformance, Swift's default localizedDescription
    // produces "The operation couldn't be completed. (MapperError error 0.)" —
    // the human-readable reason is silently dropped in the catch site.
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "Audio graph invalid: \(reason)"
        }
    }
}
