import Foundation
import SwiftUI
import Combine
import AVFoundation
import os.lock

// MARK: - Macro Node

/// A macro-node encapsulates a subgraph into a single collapsible node.
/// Double-click to expand/collapse. Exposed ports on the boundary allow
/// external connections to internal nodes.
///
/// v2.0: MacroNode is now a standalone graph abstraction with no lane dependency.
/// The internalGraph contains the complete audio processing chain.
///
/// ─────────────────────────────────────────────────────────────────────────
/// FIX 4a — COLLAPSED-RENDER PATH (closed):
/// MacroNode conforms to `DSPNode` / `GraphNodeDSPProvider`. When collapsed,
/// `render(...)` walks a cached internal `ExecutionPlan` (built on the main
/// thread via `rebuildInternalPlanIfNeeded(frameCapacity:)` and reusing
/// `ExecutionPlan.build`'s topological sort — no sort duplication) and
/// renders the internal chain's terminal `MasterOutputNode` directly into
/// the macro's own output buffer, so a collapsed macro's audio reaches the
/// parent graph's output without promoting any internal nodes.
///
/// When expanded (`isExpanded == true`), `render(...)` emits silence: the
/// internal nodes have been promoted to the parent graph by
/// `NodeGraph.expand(macroId:)` and are rendered directly by the parent
/// `ExecutionPlan`. The macro's external `out` port therefore carries
/// silence while expanded — the promoted internal chain is the live path.
/// Expand/collapse behavior is unchanged.
///
/// Real-time contract: `render(...)` performs no allocations and takes no
/// blocking locks. The internal plan is snapshotted under
/// `os_unfair_lock_trylock`; on contention — or when the fresh plan isn't
/// sized for the current block — the audio thread falls back to the last
/// plan it rendered successfully (P0 fix, Round 2 audit, TouchDesigner: a
/// hard zero sample is an infinite-slope discontinuity injected into a
/// continuous waveform, i.e. a broadband transient, not the "inaudible"
/// gap the old comment claimed). Only the very first render, before any
/// plan has ever been adopted, emits silence — there is no prior waveform
/// for that one to interrupt. Telemetry (peak/RMS per channel) is written
/// under a separate trylock so the UI can read levels without ever
/// blocking the audio thread.
/// ─────────────────────────────────────────────────────────────────────────
class MacroNode: BaseGraphNode {

    // MARK: - Internal Graph
    
    /// The internal node graph contained within this macro.
    var internalGraph: NodeGraph
    
    /// Port mapping: external port ID → internal (nodeId, portId).
    /// When a signal enters the macro's input port, it's routed to the
    /// corresponding internal node's port.
    var portMappings: [String: (nodeId: UUID, portId: String)] = [:]

    // MARK: - Collapsed-render state (Fix 4a)
    //
    // Cached internal `ExecutionPlan` for the collapsed-render path. Built
    // on the main thread by `rebuildInternalPlanIfNeeded(frameCapacity:)`,
    // which calls `ExecutionPlan.build` on `internalGraph` — reusing the
    // existing topological sort, no duplication. The audio thread snapshots
    // this pointer under `planLock` (trylock; fallback = `lastGoodPlan`,
    // below — see `render` for why silence is no longer the fallback).
    private var internalPlan: ExecutionPlan?
    private var planLock = os_unfair_lock_s()

    /// P0 fix (Round 2 audit, TouchDesigner) — the last plan this node
    /// actually rendered. Read and written EXCLUSIVELY on the audio thread
    /// inside `render(...)` below, so it needs no lock of its own: it is
    /// the audio thread's fallback when `planLock` is contended (main
    /// thread mid-swap) or the fresh snapshot isn't sized for this block,
    /// so a collapsed macro keeps rendering its previous, already-flowing
    /// plan instead of splicing in a hard zero (see `render` doc below).
    private var lastGoodPlan: ExecutionPlan?

    /// Pre-allocated scratch for gathering per-step input `AudioBuffer`
    // pointers inside `render`. Sized to the same generous upper bound used
    // by `GraphAudioEngine.maxInputsPerNode`. Allocated once at init,
    // reused on every render — never touches the allocator from the audio
    // thread.
    private static let maxInputsPerNode: Int = 16
    private let inputsScratch: UnsafeMutablePointer<AudioBuffer>
    private let scratchPlaceholderL: UnsafeMutablePointer<Float>
    private let scratchPlaceholderR: UnsafeMutablePointer<Float>

    /// Parent-step input-port map, handed to this macro by
    /// `ExecutionPlan.build` when the parent plan is constructed. Updated
    /// on the main thread only; read by the audio thread only after the
    /// routing snapshot is copied at the top of `render(...)`.
    var parentStepInputPortIndexMap: [String: Int] = [:]

    /// Pre-computed routing from parent audio input slots to internal buffer
    /// slots. Computed on the main thread in `rebuildInternalPlanIfNeeded`
    /// once both the parent map and the internal plan are known. Copied to
    /// a local variable at the top of `render(...)` so the audio thread sees
    /// a consistent value without blocking locks.
    private var externalInputRouting: [String: ExternalInputRoute] = [:]

    /// Last rendered block's peak/RMS per channel. Written by the audio
    // thread under `telemetryLock` (trylock; a missed update just leaves a
    // stale reading — inaudible). Read by the UI via `telemetrySnapshot`.
    private var macroTelemetry = MacroTelemetry()
    private var telemetryLock = os_unfair_lock_s()

    
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

        // Pre-allocate the render scratch (Fix 4a). One-time allocation,
        // reused for the lifetime of the macro — never re-allocated from
        // the audio thread.
        self.scratchPlaceholderL = .allocate(capacity: 1)
        self.scratchPlaceholderL.initialize(to: 0)
        self.scratchPlaceholderR = .allocate(capacity: 1)
        self.scratchPlaceholderR.initialize(to: 0)
        let placeholder = AudioBuffer(
            left: self.scratchPlaceholderL,
            right: self.scratchPlaceholderR,
            frameCapacity: 0
        )
        self.inputsScratch = .allocate(capacity: MacroNode.maxInputsPerNode)
        self.inputsScratch.initialize(
            repeating: placeholder,
            count: MacroNode.maxInputsPerNode
        )

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

    // MARK: - Collapsed-render plan management (Fix 4a)

    /// Rebuild the cached internal `ExecutionPlan` used by the collapsed
    /// render path. Main-thread only — allocates a `BufferPool`. Called
    /// by `NeuralEngine.rebuildAudioGraphIfNeeded()` before audio starts
    /// and on every topology change, so the audio thread always observes
    /// a fully-formed plan (or none at all) under `planLock`.
    func rebuildInternalPlanIfNeeded(frameCapacity: Int) {
        guard let basePlan = ExecutionPlan.build(
            from: internalGraph,
            frameCapacity: frameCapacity
        ) else {
            os_unfair_lock_lock(&planLock)
            internalPlan = nil
            os_unfair_lock_unlock(&planLock)
            externalInputRouting = [:]
            return
        }

        // P1 — collapsed macro external input routing: reserve a dedicated
        // buffer slot for every mapped external audio input port so the
        // parent graph can copy its signal into the macro's internal plan.
        // Existing internal slots are preserved; new slots are appended after
        // them so internal indices remain stable.
        let externalAudioInputs = _ports
            .filter { $0.direction == .input && $0.signalType == .audio }
            .compactMap { port -> (String, UUID, String)? in
                guard let mapping = portMappings[port.id] else { return nil }
                return (port.id, mapping.nodeId, mapping.portId)
            }
        let plan = externalAudioInputs.isEmpty
            ? basePlan
            : basePlan.planAddingExternalAudioInputs(externalAudioInputs)

        os_unfair_lock_lock(&planLock)
        internalPlan = plan
        os_unfair_lock_unlock(&planLock)

        // Once both the parent step's input-port map (handed to us by
        // `ExecutionPlan.build`) and the internal plan are available,
        // pre-compute every connected route. Empty `portMappings` or an
        // unconnected external port yields an empty routing table, which
        // keeps the no-external-inputs path fast and identical to the
        // pre-fix behavior.
        computeExternalInputRouting()
    }

    /// Pre-compute the mapping from parent audio input slots to internal
    /// buffer slots. Main-thread only; relies on `parentStepInputPortIndexMap`
    /// (set by `ExecutionPlan.build`) and the macro's `portMappings`.
    private func computeExternalInputRouting() {
        guard let plan = internalPlan else {
            externalInputRouting = [:]
            return
        }
        var routing: [String: ExternalInputRoute] = [:]
        for (externalPortId, internalTarget) in portMappings {
            guard let parentInputIndex = parentStepInputPortIndexMap[externalPortId],
                  let internalStep = plan.steps.first(where: { $0.nodeId == internalTarget.nodeId }),
                  let internalInputIndex = internalStep.inputPortIndexMap[internalTarget.portId] else {
                continue
            }
            let internalBufferSlot = internalStep.inputBufferIndices[internalInputIndex]
            routing[externalPortId] = ExternalInputRoute(
                parentInputIndex: parentInputIndex,
                internalBufferSlot: internalBufferSlot
            )
        }
        externalInputRouting = routing
    }

    /// Latest peak/RMS snapshot for UI meters (P4 VU). Thread-safe for
    /// main-thread reads — uses `os_unfair_lock_trylock` so a UI poll can
    /// never block on the audio thread. Returns zeros if the lock is
    /// contended or the macro hasn't rendered yet.
    var telemetrySnapshot: MacroTelemetry {
        var snap = MacroTelemetry()
        if os_unfair_lock_trylock(&telemetryLock) {
            snap = macroTelemetry
            os_unfair_lock_unlock(&telemetryLock)
        }
        return snap
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

        // Pre-allocate the render scratch (Fix 4a) — same pattern as the
        // designated init.
        self.scratchPlaceholderL = .allocate(capacity: 1)
        self.scratchPlaceholderL.initialize(to: 0)
        self.scratchPlaceholderR = .allocate(capacity: 1)
        self.scratchPlaceholderR.initialize(to: 0)
        let placeholder = AudioBuffer(
            left: self.scratchPlaceholderL,
            right: self.scratchPlaceholderR,
            frameCapacity: 0
        )
        self.inputsScratch = .allocate(capacity: MacroNode.maxInputsPerNode)
        self.inputsScratch.initialize(
            repeating: placeholder,
            count: MacroNode.maxInputsPerNode
        )

        // Call super init
        try super.init(from: decoder)
    }

    deinit {
        inputsScratch.deinitialize(count: MacroNode.maxInputsPerNode)
        inputsScratch.deallocate()
        scratchPlaceholderL.deinitialize(count: 1)
        scratchPlaceholderL.deallocate()
        scratchPlaceholderR.deinitialize(count: 1)
        scratchPlaceholderR.deallocate()
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

// MARK: - External Input Routing (P1 — collapsed macro input portMappings)

/// A single pre-computed route from one parent audio input slot into one
/// internal buffer slot. Used by `MacroNode.render` to inject external
/// signals into the macro's internal graph without any runtime lookup.
struct ExternalInputRoute {
    /// Index into the `inputs` buffer pointer passed to `MacroNode.render`.
    let parentInputIndex: Int
    /// `BufferPool` slot index inside the macro's internal plan that the
    /// mapped internal node reads from.
    let internalBufferSlot: Int
}

// MARK: - MacroTelemetry (P4 VU meter source)

/// Per-block level telemetry for a `MacroNode`. Written by the audio
/// thread at the end of `MacroNode.render(...)` and read by the PERFORM
/// mixer VU meters (P4). Plain value type — the cross-thread handoff is
/// handled by `MacroNode.telemetryLock`, not by the struct itself.
struct MacroTelemetry {
    var peakL: Float = 0
    var peakR: Float = 0
    var rmsL: Float = 0
    var rmsR: Float = 0
}

// MARK: - MacroNode + DSPNode (collapsed-render path, Fix 4a)

extension MacroNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    /// Pull-render entry point for a collapsed macro.
    ///
    /// Strategy: snapshot the cached internal `ExecutionPlan` (built by
    /// `rebuildInternalPlanIfNeeded(frameCapacity:)` on the main thread)
    /// and walk its steps in topological order. Each step's `dspNode`
    /// renders into its assigned `BufferPool` slot; the terminal step
    /// (the internal `MasterOutputNode`, marked by
    /// `ExecutionPlan.terminalSlot`) renders directly into this macro's
    /// own `output` buffer — that is the audio the parent graph picks up
    /// from the macro's pool slot.
    ///
    /// When expanded, the internal nodes have been promoted to the parent
    /// graph by `NodeGraph.expand(macroId:)` and are rendered by the
    /// parent `ExecutionPlan` directly; this method emits silence to
    /// avoid double-rendering.
    ///
    /// Real-time safety: no allocations, no blocking locks. The plan
    /// snapshot is taken under `os_unfair_lock_trylock`; on lock
    /// contention (or an unready/undersized plan) the macro falls back to
    /// `lastGoodPlan` — the plan it rendered last call — rather than
    /// zeroing the output. Telemetry is written under a separate trylock
    /// so a UI read can never block on the audio thread.
    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        let bytes = frameCount * MemoryLayout<Float>.stride

        // Expanded: internal nodes are promoted and rendered by the parent
        // plan. Contribute silence so the macro's external `out` edge
        // carries nothing (no double-render).
        guard !isExpanded else {
            memset(output.left, 0, bytes)
            memset(output.right, 0, bytes)
            return
        }

        // Snapshot the cached internal plan under trylock — never block.
        var planSnapshot: ExecutionPlan?
        if os_unfair_lock_trylock(&planLock) {
            planSnapshot = internalPlan
            os_unfair_lock_unlock(&planLock)
        }

        // P0 fix (Round 2, TouchDesigner) — on lock contention (main thread
        // mid plan-swap) or a plan that isn't sized for this block,
        // `planSnapshot` is nil or unusable. The old code zeroed `output`
        // here; that stomps a continuous waveform with an infinite-slope
        // discontinuity (a broadband transient), not an inaudible gap.
        // Fall back to `lastGoodPlan` so the audio thread keeps rendering
        // the previous, already-flowing plan instead of splicing in
        // silence. `lastGoodPlan` is read/written exclusively here on the
        // audio thread, so it needs no lock of its own.
        var plan: ExecutionPlan?
        if let fresh = planSnapshot, frameCount <= fresh.frameCapacity {
            plan = fresh
        } else if let cached = lastGoodPlan, frameCount <= cached.frameCapacity {
            plan = cached
        }

        guard let plan else {
            // Nothing renderable yet — only possible before this macro's
            // very first successful plan build. No prior waveform exists
            // to interrupt, so silence here is a startup condition, not a
            // mid-stream splice.
            memset(output.left, 0, bytes)
            memset(output.right, 0, bytes)
            return
        }
        lastGoodPlan = plan

        let pool = plan.bufferPool
        let scratch = self.inputsScratch
        let scratchCap = MacroNode.maxInputsPerNode

        // P1 — inject any connected external audio inputs into the internal
        // buffer slots before the internal chain runs. The routing table was
        // pre-computed on the main thread; the local copy here is a value-type
        // snapshot so the audio thread never reads a half-updated dictionary.
        let routes = externalInputRouting
        for route in routes.values {
            guard route.parentInputIndex < inputs.count else { continue }
            let src = inputs[route.parentInputIndex]
            let dst = pool.buffer(at: route.internalBufferSlot)
            memcpy(dst.left, src.left, bytes)
            memcpy(dst.right, src.right, bytes)
        }

        for step in plan.steps {
            let inputCount = min(step.inputBufferIndices.count, scratchCap)
            for k in 0..<inputCount {
                scratch[k] = pool.buffer(at: step.inputBufferIndices[k])
            }
            let inputsBuf = UnsafeBufferPointer(start: scratch, count: inputCount)

            if step.outputBufferIndex == ExecutionPlan.terminalSlot {
                // Internal terminal (MasterOutputNode): render directly
                // into this macro's output buffer — that is the audio the
                // parent graph will read from the macro's pool slot.
                step.dspNode.render(
                    inputs: inputsBuf,
                    output: output,
                    frameCount: frameCount,
                    sampleRate: sampleRate
                )
            } else {
                let outBuf = pool.buffer(at: step.outputBufferIndex)
                step.dspNode.render(
                    inputs: inputsBuf,
                    output: outBuf,
                    frameCount: frameCount,
                    sampleRate: sampleRate
                )
            }
        }

        computeTelemetry(output: output, frameCount: frameCount)
    }

    /// Reset every node in the cached internal plan (clears filter state,
    /// delay lines, oscillator phase). Safe from any thread.
    func reset() {
        var plan: ExecutionPlan?
        if os_unfair_lock_trylock(&planLock) {
            plan = internalPlan
            os_unfair_lock_unlock(&planLock)
        }
        plan?.steps.forEach { $0.dspNode.reset() }
    }

    /// Peak/RMS per channel for the just-rendered block. Written under
    /// `telemetryLock` (trylock — a missed update leaves a stale reading,
    /// which is inaudible and fine for a VU meter).
    private func computeTelemetry(output: AudioBuffer, frameCount: Int) {
        guard frameCount > 0 else { return }
        var peakL: Float = 0
        var peakR: Float = 0
        var sumSqL: Float = 0
        var sumSqR: Float = 0
        for i in 0..<frameCount {
            let l = output.left[i]
            let r = output.right[i]
            let al = abs(l)
            let ar = abs(r)
            if al > peakL { peakL = al }
            if ar > peakR { peakR = ar }
            sumSqL += l * l
            sumSqR += r * r
        }
        let invN = 1.0 / Float(frameCount)
        let t = MacroTelemetry(
            peakL: peakL,
            peakR: peakR,
            rmsL: sqrtf(sumSqL * invN),
            rmsR: sqrtf(sumSqR * invN)
        )
        if os_unfair_lock_trylock(&telemetryLock) {
            macroTelemetry = t
            os_unfair_lock_unlock(&telemetryLock)
        }
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

    /// Neural inference surface (e.g., ACEStepInferenceNode)
    /// Parameter-only companion to the resonator loop.
    case neural

    /// Header label shown on canvas cards (stage name > type name).
    var headerLabel: String {
        switch self {
        case .seed:      return "SEED"
        case .resonator: return "RESONATOR"
        case .spectra:   return "SPECTRA"
        case .ladder:    return "LADDER"
        case .echo:      return "ECHO"
        case .flat:      return "FLAT"
        case .neural:    return "NEURAL"
        }
    }

    /// Sparse accent color from the design system (no category-purple fallback).
    var accentColor: Color {
        typealias DS = LRConstants.DS
        switch self {
        case .seed:      return DS.stageSeed
        case .resonator: return DS.stageResonator
        case .spectra:   return DS.stageSpectra
        case .ladder:    return DS.stageLadder
        case .echo:      return DS.stageEcho
        case .flat:      return DS.stageFlat
        case .neural:    return DS.stageNeural
        }
    }

    /// Decode topology JSON aliases (`spectral` → `spectra`, etc.).
    static func resolve(_ raw: String?) -> StageKind? {
        guard let raw = raw?.lowercased() else { return nil }
        if let kind = StageKind(rawValue: raw) { return kind }
        switch raw {
        case "spectral": return .spectra
        default:         return nil
        }
    }

    /// Infer stage from node type when topology JSON omits `stageKind`.
    ///
    /// BUG 4 fix: kept in sync with the worked examples each `StageKind`
    /// case already documents above (`"e.g., LadderFilter + Agitation"`,
    /// `"e.g., MasterOutput, Mixer"`, ...) — several of those named node
    /// types were missing (or misspelled) here, so on any topology that
    /// omits an explicit `stageKind`, those cards fell through to `nil`
    /// and lost their stage badge/accent color on the STAGES canvas
    /// (`NodeCardChrome.header`) even though the enum's own docs already
    /// called them out as belonging to a specific stage:
    ///   - `"noise"` is the real registered `NodeFactory` type (the old
    ///     `"noise_generator"` string matches nothing `NodeFactory` creates).
    ///   - `"agitation"` — named alongside `LadderFilter` in `.ladder`'s doc.
    ///   - `"mixer"` — named alongside `MasterOutput` in `.flat`'s doc.
    ///   - `"reverb"` — a time-based effect like `delay_line`, `.echo`'s doc.
    ///   - `"prompt_bank"` — a parameter-surface companion to
    ///     `ace_step_inference`/`prompt_engine`, same `.neural` family.
    static func inferred(for node: any GraphNode) -> StageKind? {
        switch node.nodeType {
        case "feedback_loop":                          return .resonator
        case "oscillator", "noise",
             "audio_input", "koenig_seed", "exciter": return .seed
        case "master_output", "mixer":                 return .flat
        case "delay_line", "delay", "reverb":          return .echo
        case "ladder_filter", "agitation":             return .ladder
        case "ace_step_inference", "prompt_engine",
             "prompt_bank":                            return .neural
        case "spectral_chain", "spectral_processor",
             "spectral_analyzer", "spectral_feedback":  return .spectra
        default:                                       return nil
        }
    }
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
        guard let kind = effectiveStageKind else {
            return "Unclassified"
        }
        switch kind {
        case .seed:       return "Seed - Signal Origin"
        case .resonator:  return "Resonator - Neural Core"
        case .spectra:    return "Spectra - Frequency Sculpting"
        case .ladder:     return "Ladder - Analog Filter"
        case .echo:       return "Echo - Temporal Feedback"
        case .flat:       return "Flat - Direct Output"
        case .neural:     return "Neural - Inference Surface"
        }
    }

    /// Color associated with this stage kind (for UI visualization).
    var stageColor: Color {
        effectiveStageKind?.accentColor ?? LRConstants.DS.textTertiary
    }

    /// Pull legacy `internalGraph.metadata["stageKind"]` onto `BaseGraphNode.stageKind`.
    func migrateStageKindFromMetadataIfNeeded() {
        guard stageKind == nil,
              let raw = internalGraph.metadata["stageKind"] else { return }
        stageKind = StageKind.resolve(raw)
    }
}
