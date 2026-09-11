import Foundation

// MARK: - Audio Pipeline Validator (P3.13 Surgical Slice 5)
//
// Stateless helper that owns the *pure, graph-only* half of
// `NeuralEngine.verifyAudioPipeline()` and the whole of
// `NeuralEngine.restoreSilentSources()`. Extracted (behavior-preserving)
// from the `NeuralEngine` god-class as the FINAL slice of the P3.13
// split. The instance methods `NeuralEngine.verifyAudioPipeline()` and
// `NeuralEngine.restoreSilentSources()` now delegate here for the parts
// that do NOT touch CoreAudio / `AVAudioEngine` / `GraphAudioEngine`,
// so the graph-audit + source-restore paths can be unit-tested without
// instantiating `NeuralEngine` (which would mutate the system output
// device sample rate via `AudioObjectSetPropertyData` and spawn the
// Python ACE-Step bridge process — unacceptable side effects for a
// unit test).
//
// What stays inline in `NeuralEngine` (see `TODO(future)` markers there):
//   - `audioEngine.isRunning`            (AVAudioEngine state)
//   - `graphAudioEngine.currentPlanStepCount` (GraphAudioEngine ownership)
//   - `effectiveFormat.sampleRate` print  (AVAudioFormat)
//   - `configureOutputDevice` / `restoreDeviceSampleRate`
//     (CoreAudio `AudioObjectSetPropertyData`)
//   - `setupMasterMixer` / `startProcessing` / `stopProcessing`
//     (mutate the `AVAudioEngine` + audio unit; real-time invariants)
//   - `rebuildAudioGraphIfNeeded` (orchestrates `GraphAudioEngine` rebuild)
//   - `audioInputBuffer` + tap install/remove (CoreAudio tap installation)
//
// `notify` is invoked in the same places the original instance method
// called `objectWillChange.send()`, so observable behavior is identical.
// `restoreSilentSources` does NOT call `notify` today (the original
// didn't — `startProcessing` re-runs `verifyAudioPipeline()` right
// after, which writes `lastPipelineStatus`, so the UI refreshes via
// that path); the `notify` parameter is reserved for future use and
// kept in the signature for API consistency with the other P3.13
// controllers.
//
// White paper reference:
//   §3.3 -- Recursive formula per macro
//   §6.1 -- Black Box Resonator (each macro is one resonator)

/// Stateless owner of the pure, graph-only audio-pipeline audit and
/// silent-source restore paths.
///
/// A caseless enum is used (rather than a `struct`) to make accidental
/// instantiation impossible — there is no instance state to carry.
enum AudioPipelineValidator {

    // MARK: - Graph Audit

    /// Pure-graph result of `auditGraph(nodeGraph:)`. Mirrors the
    /// graph-derived fields of `NeuralEngine.PipelineStatus` plus a
    /// human-readable `warnings` list. The system-coupled fields
    /// (`engineRunning`, `attachedNodeCount`) are filled in by
    /// `NeuralEngine.verifyAudioPipeline()` after this audit returns.
    struct GraphAudit: Equatable {
        /// DSP-participating node count (anything whose `dspNode()`
        /// returns non-nil). Same definition as
        /// `PipelineStatus.audioNodeCount`.
        var audioNodeCount: Int = 0

        /// Source node count (DSP-participating nodes with no incoming
        /// `.audio` edge). Same definition as
        /// `PipelineStatus.sourceNodeCount`.
        var sourceNodeCount: Int = 0

        /// `MasterOutputNode` instances in the graph.
        var masterOutputCount: Int = 0

        /// True iff at least one source is audible (osc amp>threshold &&
        /// freq>0, OR noise amp>threshold). Same definition as
        /// `PipelineStatus.sourceActive`.
        var sourceActive: Bool = false

        /// First master output's `volume` (0 if no master present).
        var masterVolume: Float = 0.0

        /// Human-readable warnings for graph-only defects. Faithful
        /// extraction of the checks already implicit in
        /// `PipelineStatus.isHealthy` / `silenceReason`; does NOT add
        /// new checks the original code did not perform.
        ///
        /// TODO(future): disconnected-node detection is NOT implemented
        /// here — the original `verifyAudioPipeline()` did not detect
        /// nodes with no in/out edges either. A node floating in the
        /// graph with zero connections passes this audit today. Adding
        /// that check is a behavior change and was intentionally left
        /// out of this slice to keep the extraction verbatim.
        var warnings: [String] = []
    }

    /// Walk `nodeGraph.nodes` / `.edges` and return the graph-derived
    /// fields of `PipelineStatus` plus a warnings list. Pure: no
    /// CoreAudio, no `AVAudioEngine`, no `GraphAudioEngine`, no stdout.
    ///
    /// Pinned to current `NeuralEngine.verifyAudioPipeline()` behavior
    /// (P3.13 Slice 5). The warnings list is a faithful re-statement
    /// of the conditions already implicit in
    /// `PipelineStatus.isHealthy` / `silenceReason` — no new checks.
    static func auditGraph(nodeGraph: NodeGraph) -> GraphAudit {
        var audit = GraphAudit()

        // 1. DSP-participating nodes (anything that publishes a non-nil
        //    dspNode()). Verbatim from NeuralEngine.verifyAudioPipeline.
        let dspParticipating = nodeGraph.nodes.values.compactMap { node -> (any GraphNode)? in
            guard let provider = node as? GraphNodeDSPProvider, provider.dspNode() != nil else { return nil }
            return node
        }

        // 2. Sources = DSP-participating nodes with no incoming .audio edge,
        //    excluding sinks such as the master output.
        let sources = dspParticipating.filter { node in
            guard !(node is MasterOutputNode) else { return false }
            return !nodeGraph.edges.values.contains { $0.targetNodeId == node.id && $0.signalType == .audio }
        }

        // 3. Master outputs.
        let masterOutputs = nodeGraph.nodes.values.compactMap { $0 as? MasterOutputNode }

        audit.audioNodeCount = dspParticipating.count
        audit.sourceNodeCount = sources.count
        audit.masterOutputCount = masterOutputs.count

        // 4. Source activity — same logic as the original.
        for source in sources {
            if let osc = source as? OscillatorNode {
                audit.sourceActive = audit.sourceActive
                    || (osc.amplitude > LRConstants.silentAmplitudeThreshold && osc.frequency > 0)
            } else if let noise = source as? NoiseNode {
                audit.sourceActive = audit.sourceActive
                    || noise.amplitude > LRConstants.silentAmplitudeThreshold
            }
        }

        // 5. Master volume — first master output only (matches original).
        if let master = masterOutputs.first {
            audit.masterVolume = master.volume
        }

        // 6. Warnings — faithful re-statement of the conditions already
        //    implicit in `PipelineStatus.isHealthy` / `silenceReason`.
        //    Order matches `silenceReason`'s priority (most actionable
        //    first) so callers can surface the same reason the original
        //    computed.
        if audit.sourceNodeCount == 0 {
            audit.warnings.append("no source")
        }
        if audit.sourceNodeCount > 0 && !audit.sourceActive {
            audit.warnings.append("amp=0")
        }
        if audit.masterOutputCount == 0 {
            audit.warnings.append("no master")
        }
        if audit.masterOutputCount > 1 {
            audit.warnings.append("multiple master outputs")
        }
        if audit.masterOutputCount >= 1 && audit.masterVolume <= 0.01 {
            audit.warnings.append("master=0")
        }
        // TODO(future): disconnected-node detection — see GraphAudit.warnings doc.

        return audit
    }

    // MARK: - Silent Source Restore

    /// Lifts every source node's amplitude back to
    /// `LRConstants.autoRestoreAmplitude` wherever it's at/near zero
    /// (`<= LRConstants.silentAmplitudeThreshold`). Verbatim port of
    /// `NeuralEngine.restoreSilentSources()`.
    ///
    /// Called exactly once from `NeuralEngine.startProcessing()` when
    /// `verifyAudioPipeline()` reports sources exist but none are
    /// active — never from `render()` or any continuous/timed path, so
    /// a performer fading a source out live is never overridden.
    ///
    /// - Parameters:
    ///   - nodeGraph: The graph whose source nodes should be inspected
    ///     and restored in place.
    ///   - notify: Reserved side-effect callback for future use. The
    ///     original `NeuralEngine.restoreSilentSources()` did NOT call
    ///     `objectWillChange.send()` (the caller re-runs
    ///     `verifyAudioPipeline()` immediately after, which writes
    ///     `lastPipelineStatus` and refreshes the UI through that
    ///     path); to preserve behavior verbatim this implementation
    ///     does not invoke `notify` either. See TODO(future) below.
    static func restoreSilentSources(nodeGraph: NodeGraph, notify: () -> Void) {
        for node in nodeGraph.nodes.values {
            if let osc = node as? OscillatorNode,
               osc.amplitude <= LRConstants.silentAmplitudeThreshold {
                print(">> RESTORED amp \(osc.amplitude) → \(LRConstants.autoRestoreAmplitude) (was silent) -- source '\(osc.name)'")
                osc.amplitude = LRConstants.autoRestoreAmplitude
            } else if let noise = node as? NoiseNode,
                      noise.amplitude <= LRConstants.silentAmplitudeThreshold {
                print(">> RESTORED amp \(noise.amplitude) → \(LRConstants.autoRestoreAmplitude) (was silent) -- source '\(noise.name)'")
                noise.amplitude = LRConstants.autoRestoreAmplitude
            }
        }
        // TODO(future): the original `restoreSilentSources()` did not
        // call `objectWillChange.send()`. `notify` is intentionally
        // unused to preserve behavior verbatim. If a future slice
        // wants the UI to refresh the moment a source is restored
        // (rather than on the next `verifyAudioPipeline()` write to
        // `lastPipelineStatus`), invoke `notify()` here and add a
        // test pinning that side effect.
        _ = notify
    }
}
