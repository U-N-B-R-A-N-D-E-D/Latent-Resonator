import Foundation

// MARK: - ExecutionPlan

/// A pre-computed render order for one snapshot of the `NodeGraph`
/// topology.
///
/// Each `Step` says: "run this `DSPNode`, read its inputs from these
/// `BufferPool` slots, write its output to that slot." The terminal step
/// uses `outputBufferIndex == terminalSlot` to mean «write directly into
/// the AVAudioSourceNode's ABL».
///
/// Plans are immutable once built. Topology changes generate a brand-new
/// plan and atomically swap it into the running `GraphAudioEngine` (see
/// `GraphAudioEngine.adopt(_:)`). The audio thread always sees a fully
/// formed plan or none at all — never a half-built one.
final class ExecutionPlan {

    /// Sentinel meaning «write to the engine's terminal output (the ABL)
    /// instead of a `BufferPool` slot». Reserved for the master output
    /// step, of which there is exactly one per plan.
    static let terminalSlot: Int = -1

    struct Step {
        /// The graph node this step renders.
        let nodeId: UUID

        /// The DSP body. Resolved at plan-build time so the audio thread
        /// never has to walk the graph dictionary.
        let dspNode: DSPNode

        /// Buffer-pool slots this step reads from. Length equals the node's
        /// audio-input port count (sorted by port id for stability).
        let inputBufferIndices: [Int]

        /// Map from audio input `targetPortId` to the index within
        /// `inputBufferIndices`. Lets nodes (notably `MacroNode`) resolve
        /// which physical input slot corresponds to a named port without
        /// re-scanning edges on the audio thread. Built on the main thread
        /// during plan construction; read-only on the audio thread.
        let inputPortIndexMap: [String: Int]

        /// Buffer-pool slot this step writes to, OR `ExecutionPlan.terminalSlot`
        /// if this is the master output and the engine should write to
        /// the ABL instead.
        let outputBufferIndex: Int

    }

    let steps: [Step]
    let bufferPool: BufferPool
    let frameCapacity: Int
    let terminalNodeId: UUID?

    fileprivate init(
        steps: [Step],
        bufferPool: BufferPool,
        frameCapacity: Int,
        terminalNodeId: UUID?
    ) {
        self.steps = steps
        self.bufferPool = bufferPool
        self.frameCapacity = frameCapacity
        self.terminalNodeId = terminalNodeId
    }
}

// MARK: - Plan builder

extension ExecutionPlan {

    /// Build an `ExecutionPlan` from the current `NodeGraph` topology.
    ///
    /// Process:
    /// 1. Run `NodeGraph.topologicalSort()` to obtain sources-first order.
    /// 2. Filter to nodes that expose a non-nil `dspNode()` (participating
    ///    nodes). Non-participating nodes are silently skipped — useful
    ///    while the migration to `DSPNode` is in flight.
    /// 3. Identify the terminal node — the first `MasterOutputNode` if
    ///    present, otherwise the last leaf among participating nodes
    ///    (no outgoing audio edges).
    /// 4. Assign one `BufferPool` slot to every non-terminal participating
    ///    node. Terminal writes to the ABL (`terminalSlot`).
    /// 5. For each step, gather incoming audio edges sorted by
    ///    `targetPortId` so that mixer-style nodes receive their inputs
    ///    in `in0`, `in1`, … order.
    ///
    /// `MacroNode` now participates (Fix 4a closed): it conforms to
    /// `GraphNodeDSPProvider` / `DSPNode`, so a collapsed macro renders its
    /// `internalGraph` through its own cached internal `ExecutionPlan`
    /// (built here on the same `internalGraph`) and writes the internal
    /// terminal into its own output buffer. Expanded macros still
    /// participate — they emit silence in `render(...)` while their
    /// promoted internal nodes are rendered directly by this parent plan.
    ///
    /// - Returns: A plan, or `nil` if the graph has no participating DSP
    ///   nodes (engine renders silence in that case).
    static func build(
        from graph: NodeGraph,
        frameCapacity: Int
    ) -> ExecutionPlan? {
        let topo = graph.topologicalSort()

        // Collect participating nodes in topo order. MacroNode now conforms
        // (Fix 4a) and is no longer skipped here.
        var participating: [(UUID, DSPNode)] = []
        participating.reserveCapacity(topo.count)
        for nid in topo {
            guard let node = graph.nodes[nid] as? GraphNodeDSPProvider,
                  let dsp = node.dspNode() else {
                continue
            }
            participating.append((nid, dsp))
        }

        guard !participating.isEmpty else { return nil }

        // Identify terminal node: prefer MasterOutputNode, fallback to leaf.
        let audioEdges = graph.edges.values.filter { $0.signalType == .audio }
        let nodesWithOutgoing: Set<UUID> = Set(audioEdges.map { $0.sourceNodeId })

        var terminalId: UUID? = nil
        for (nid, _) in participating {
            if graph.nodes[nid] is MasterOutputNode {
                terminalId = nid
                break
            }
        }
        if terminalId == nil {
            // Fall back to last participating node that has no outgoing audio edges.
            for (nid, _) in participating.reversed() where !nodesWithOutgoing.contains(nid) {
                terminalId = nid
                break
            }
        }

        // Assign buffer slots to non-terminal participating nodes
        var bufferIndex: [UUID: Int] = [:]
        var nextSlot = 0
        for (nid, _) in participating where nid != terminalId {
            bufferIndex[nid] = nextSlot
            nextSlot += 1
        }

        // BufferPool needs at least one slot even if everything is the terminal.
        let pool = BufferPool(count: max(nextSlot, 1), frameCapacity: frameCapacity)

        // Walk topo order, build steps
        var steps: [Step] = []
        steps.reserveCapacity(participating.count)
        for (nid, dsp) in participating {
            let isTerminal = (nid == terminalId)

            // Audio inputs into this node, sorted by target port id for stable
            // multi-input ordering (Mixer in0 < in1 < in2 < in3).
            let incoming = audioEdges
                .filter { $0.targetNodeId == nid }
                .sorted { $0.targetPortId < $1.targetPortId }

            var inputs: [Int] = []
            var inputPortIndexMap: [String: Int] = [:]
            inputs.reserveCapacity(incoming.count)
            inputPortIndexMap.reserveCapacity(incoming.count)
            for (index, edge) in incoming.enumerated() {
                inputPortIndexMap[edge.targetPortId] = index
                if let slot = bufferIndex[edge.sourceNodeId] {
                    inputs.append(slot)
                }
                // Edges from non-participating sources are silently skipped;
                // the receiving node will see fewer inputs than its port
                // count, which is the right behavior during migration.
            }

            // Hand the parent step's input-port map to a MacroNode so it can
            // pre-compute external-input routing once its internal plan is
            // rebuilt. This is the only cross-node mutation performed during
            // plan build; it runs on the main thread and is read-only on the
            // audio thread (via the macro's `externalInputRouting` snapshot).
            if let macroNode = graph.nodes[nid] as? MacroNode {
                macroNode.parentStepInputPortIndexMap = inputPortIndexMap
                // Rebuild the macro's internal plan now that the parent
                // input-port map is known, so external-input routing is
                // computed against the correct parent map and internal plan.
                macroNode.rebuildInternalPlanIfNeeded(frameCapacity: frameCapacity)
            }

            let outputIndex = isTerminal ? terminalSlot : (bufferIndex[nid] ?? 0)
            steps.append(Step(
                nodeId: nid,
                dspNode: dsp,
                inputBufferIndices: inputs,
                inputPortIndexMap: inputPortIndexMap,
                outputBufferIndex: outputIndex
            ))
        }

        return ExecutionPlan(
            steps: steps,
            bufferPool: pool,
            frameCapacity: frameCapacity,
            terminalNodeId: terminalId
        )
    }
}

// MARK: - External audio input slot injection (collapsed macro inputs)

extension ExecutionPlan {
    /// Returns a new plan with extra `BufferPool` slots reserved for external
    /// audio inputs into a macro's internal graph. The internal steps that
    /// receive external inputs get their `inputBufferIndices` and
    /// `inputPortIndexMap` updated to include the new slots, keeping the
    /// target-port-id sort order that mixer-style nodes rely on.
    ///
    /// - Parameter externalInputs: `(externalPortId, internalNodeId, internalPortId)`
    ///   tuples describing each mapped external audio input port.
    func planAddingExternalAudioInputs(
        _ externalInputs: [(externalPortId: String, internalNodeId: UUID, internalPortId: String)]
    ) -> ExecutionPlan {
        guard !externalInputs.isEmpty else { return self }

        // Assign each external input a fresh buffer slot appended after the
        // existing internal slots, so existing indices remain valid.
        var externalSlotByPort: [String: Int] = [:]
        var nextSlot = bufferPool.count
        for input in externalInputs {
            externalSlotByPort[input.externalPortId] = nextSlot
            nextSlot += 1
        }

        // Group external inputs by the internal node they feed.
        var externalsByNode: [UUID: [(portId: String, slot: Int)]] = [:]
        for input in externalInputs {
            if let slot = externalSlotByPort[input.externalPortId] {
                externalsByNode[input.internalNodeId, default: []].append((input.internalPortId, slot))
            }
        }

        let newPool = BufferPool(count: bufferPool.count + externalInputs.count, frameCapacity: frameCapacity)

        let newSteps = steps.map { step -> Step in
            guard let externals = externalsByNode[step.nodeId] else {
                return Step(
                    nodeId: step.nodeId,
                    dspNode: step.dspNode,
                    inputBufferIndices: step.inputBufferIndices,
                    inputPortIndexMap: step.inputPortIndexMap,
                    outputBufferIndex: step.outputBufferIndex
                )
            }

            // Merge existing internal inputs with the new external inputs,
            // then sort by target port id to preserve mixer in0/in1/… order.
            var portToSlot: [String: Int] = [:]
            for (portId, index) in step.inputPortIndexMap {
                portToSlot[portId] = step.inputBufferIndices[index]
            }
            for (portId, slot) in externals {
                portToSlot[portId] = slot
            }
            let sorted = portToSlot.sorted { $0.key < $1.key }
            let newInputBufferIndices = sorted.map { $0.value }
            let newInputPortIndexMap = Dictionary(
                uniqueKeysWithValues: sorted.enumerated().map { (offset, pair) in (pair.key, offset) }
            )

            return Step(
                nodeId: step.nodeId,
                dspNode: step.dspNode,
                inputBufferIndices: newInputBufferIndices,
                inputPortIndexMap: newInputPortIndexMap,
                outputBufferIndex: step.outputBufferIndex
            )
        }

        return ExecutionPlan(
            steps: newSteps,
            bufferPool: newPool,
            frameCapacity: frameCapacity,
            terminalNodeId: terminalNodeId
        )
    }
}

// MARK: - Type-erasing helper

/// `ExecutionPlan.build` reads `dspNode()` through this helper so we do not
/// have to widen the public `GraphNode` protocol with associated-type
/// constraints. Every concrete node either conforms to this directly (by
/// providing a `dspNode()` implementation) or is silently treated as
/// non-participating.
protocol GraphNodeDSPProvider {
    func dspNode() -> DSPNode?
}
