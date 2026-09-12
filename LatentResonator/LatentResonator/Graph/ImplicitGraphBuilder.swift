import Foundation

// MARK: - Implicit Graph Builder

/// Builds a `NodeGraph` internal to a `MacroNode` from a v1.x `LanePreset`.
///
/// v2.0: Factory topologies in `Resources/Topologies/` are the canonical patch
/// format. Preset macros clone `LRConstants.macroInternalScaffoldTopologyFileName`
/// and overlay ACE / feedback / excitation parameters from the preset.
///
/// P0 REGRESSION NOTE (2026-07-21) — infinite recursion, fixed two ways:
///
/// `defaultFactoryTopologyFileName` ("seed-feedback-macro") is the *outer*
/// default session topology, and it is macro-based: its "Resonator Macro"
/// node carries `presetName: "BUCHLA PERC"` with no inline `internalGraph`.
/// Deserializing that node falls through `NodeFactory.createNode` to
/// `MacroNode(id:params:)`, which calls `MacroNode.fromPreset(.buchlaPerc)`,
/// which calls `ImplicitGraphBuilder.buildGraph(from:)` — this function.
/// If this function had reloaded `defaultFactoryTopologyFileName` as its own
/// scaffold (as it used to), it would deserialize the *same* macro node
/// again, calling itself again, forever: stack overflow before the app ever
/// produces sound.
///
/// Fix (b, primary): this function's scaffold is `LRConstants.
/// macroInternalScaffoldTopologyFileName` ("seed-feedback-flat"), a topology
/// that structurally contains no "macro" node — the cycle cannot start.
/// Fix (a, backstop): `presetsUnderConstruction` catches any future scaffold
/// that reintroduces a nested preset-macro reference and breaks the cycle
/// instead of recursing.
struct ImplicitGraphBuilder {

    /// Preset names currently mid-construction by `buildGraph(from:)`. Belt-
    /// and-suspenders reentrancy guard — see the P0 regression note above.
    /// Main-thread only (graph (de)serialization never happens off-thread),
    /// so a plain `Set` needs no additional synchronization.
    private static var presetsUnderConstruction: Set<String> = []

    /// Loads the macro-internal scaffold topology and applies preset parameters.
    static func buildGraph(from preset: LanePreset) -> NodeGraph {
        guard !presetsUnderConstruction.contains(preset.name) else {
            print("ImplicitGraphBuilder: reentrant buildGraph(from:) for preset '\(preset.name)' — breaking cycle, returning empty graph. This should be unreachable now that the scaffold is '\(LRConstants.macroInternalScaffoldTopologyFileName)'; if you're seeing this, that scaffold (or whatever LRConstants.macroInternalScaffoldTopologyFileName now points to) has regained a nested \"macro\" node referencing the same preset. See the P0 regression note above.")
            return NodeGraph(autoSaveEnabled: false)
        }
        presetsUnderConstruction.insert(preset.name)
        defer { presetsUnderConstruction.remove(preset.name) }

        let graph = NodeGraph(autoSaveEnabled: false)

        do {
            let serialized = try TopologyTemplates.loadSerialized(LRConstants.macroInternalScaffoldTopologyFileName)
            try graph.deserialize(serialized)
            applyPreset(preset, to: graph)
            injectDefaultSequencer(into: graph)
            return graph
        } catch {
            print("ImplicitGraphBuilder: failed to load \(LRConstants.macroInternalScaffoldTopologyFileName): \(error)")
            return graph
        }
    }

    /// Injects a `SequencerNode` with a pre-populated step grid so PERFORM's
    /// step grid / P-lock strip is alive on first launch (the focus macro's
    /// internal sequencer exists and has active steps). Control-only node —
    /// `ExecutionPlan.build` skips it via `dspNode() == nil`, so it has no
    /// audio-path impact. P-locks target params that exist on the cloned
    /// internal nodes: `feedback` on FeedbackLoopNode, `cfg` (guidanceScale)
    /// on ACEStepInferenceNode.
    private static func injectDefaultSequencer(into graph: NodeGraph) {
        let sequencer = SequencerNode()
        var grid = sequencer.stepGrid
        grid.chainLength = 8
        grid.advanceMode = .iteration
        grid.setStep(PerformanceStep(trigType: .note, feedback: 0.55), at: 0)
        grid.setStep(PerformanceStep(trigType: .skip), at: 1)
        grid.setStep(PerformanceStep(trigType: .note, cfg: 12.0, feedback: 0.65), at: 2)
        grid.setStep(PerformanceStep(trigType: .skip), at: 3)
        grid.setStep(PerformanceStep(trigType: .note, feedback: 0.45), at: 4)
        grid.setStep(PerformanceStep(trigType: .skip), at: 5)
        grid.setStep(PerformanceStep(trigType: .lock, cfg: 15.0), at: 6)
        grid.setStep(PerformanceStep(trigType: .skip), at: 7)
        sequencer.stepGrid = grid
        sequencer.x = 200
        sequencer.y = 600
        graph.nodes[sequencer.id] = sequencer
    }

    /// Overlays `LanePreset` tuning onto the cloned factory topology.
    private static func applyPreset(_ preset: LanePreset, to graph: NodeGraph) {
        for node in graph.nodes.values {
            switch node.nodeType {
            case "ace_step_inference":
                if let ace = node as? ACEStepInferenceNode {
                    ace.prompt = preset.prompt
                    ace.guidanceScale = preset.guidanceScale
                    ace.numSteps = preset.inferenceSteps
                    ace.inputStrength = preset.inputStrength
                    ace.entropy = preset.entropyLevel / 100.0
                    ace.granularity = preset.granularity / 100.0
                }
            case "feedback_loop":
                if let loop = node as? FeedbackLoopNode {
                    loop.feedback = preset.feedbackAmount
                }
            case "oscillator":
                if let osc = node as? OscillatorNode {
                    applyExcitation(preset.excitationMode, to: osc)
                }
            default:
                break
            }
        }
    }

    /// Maps legacy excitation modes onto the seed oscillator in the factory topology.
    private static func applyExcitation(_ mode: ExcitationMode, to osc: OscillatorNode) {
        switch mode {
        case .sawOsc, .sineOsc, .squareOsc, .triangleOsc, .pulseTrain:
            osc.waveform = mode
            osc.amplitude = LRConstants.autoRestoreAmplitude
        case .whiteNoise:
            osc.waveform = .whiteNoise
            osc.amplitude = LRConstants.autoRestoreAmplitude
        case .koenigSeed:
            osc.waveform = .koenigSeed
            osc.amplitude = LRConstants.autoRestoreAmplitude
        case .silence, .audioInput:
            osc.amplitude = 0.0
        }
    }
}
