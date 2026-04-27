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

        /// Buffer-pool slot this step writes to, OR `ExecutionPlan.terminalSlot`
        /// if this is the master output and the engine should write to
        /// the ABL instead.
        let outputBufferIndex: Int

        /// Control-rate values keyed by port id (Phase 1: empty; the
        /// `ControlGraphEvaluator` will populate these in a later pass).
        let controls: [String: Float]
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
    /// - Returns: A plan, or `nil` if the graph has no participating DSP
    ///   nodes (engine renders silence in that case).
    static func build(
        from graph: NodeGraph,
        frameCapacity: Int
    ) -> ExecutionPlan? {
        let topo = graph.topologicalSort()

        // Collect participating nodes in topo order
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
            inputs.reserveCapacity(incoming.count)
            for edge in incoming {
                if let slot = bufferIndex[edge.sourceNodeId] {
                    inputs.append(slot)
                }
                // Edges from non-participating sources are silently skipped;
                // the receiving node will see fewer inputs than its port
                // count, which is the right behavior during migration.
            }

            let outputIndex = isTerminal ? terminalSlot : (bufferIndex[nid] ?? 0)
            steps.append(Step(
                nodeId: nid,
                dspNode: dsp,
                inputBufferIndices: inputs,
                outputBufferIndex: outputIndex,
                controls: [:]   // Phase 1: control evaluation deferred
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

// MARK: - Type-erasing helper

/// `ExecutionPlan.build` reads `dspNode()` through this helper so we do not
/// have to widen the public `GraphNode` protocol with associated-type
/// constraints. Every concrete node either conforms to this directly (by
/// providing a `dspNode()` implementation) or is silently treated as
/// non-participating.
protocol GraphNodeDSPProvider {
    func dspNode() -> DSPNode?
}
