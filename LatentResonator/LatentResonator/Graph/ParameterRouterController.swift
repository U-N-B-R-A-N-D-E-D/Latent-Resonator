import Foundation

// MARK: - Parameter Router Controller (P3.13 Surgical Slice 4)
//
// Stateless helper that owns the parameter-routing path: taking a
// (ControlParameter, Float) pair from MIDI CC / OSC input and writing
// it into either the focus macro's parameter bag (and, where applicable,
// the internal DSP nodes that actually render audio) OR, when no macro
// is focused, straight into the main NodeGraph's typed nodes.
//
// Extracted (behavior-preserving) from `NeuralEngine.applyParameter` /
// `applyParameterToGraphNodes` / `setParameterOnNodes` as the fourth
// slice of the P3.13 "split NeuralEngine god-class" refactor. The
// instance methods on `NeuralEngine` are now thin delegators that pass
// `focusMacro`, `crossfaderPosition`, `nodeGraph`, the
// `objectWillChange.send()` side effect (as `notify`), and the
// `updateMacroMixerState` side effect (as `mixerStateUpdater`); callers
// keep the same public signatures.
//
// NAMING NOTE: this type is `ParameterRouterController` (not
// `ParameterRouter`) to avoid a duplicate-symbol collision with the
// pre-existing `enum ParameterRouter` in `Config/ParameterRouter.swift`
// (the MIDI CC scaling helper — `scaleCCToValue` / `valueToCC` /
// `defaultCCMap`). The `Controller` suffix also matches the established
// Slice 1/2 pattern (`MacroLockController`, `MacroMixerController`).
//
// WHAT STAYS IN NeuralEngine:
//   * `.crossfader` case of `applyParameter` — mutates engine state
//     (`crossfaderPosition`) and calls `applyCrossfader()`, which routes
//     through `sceneManager` (scene crossfade). Extracting it would
//     re-couple this stateless helper to scene state, violating the
//     Slice 4 "do not touch scene" constraint. See TODO(P3.13 Slice 5).
//   * `setupMIDIRouting` — registers closures on `midiInput` /
//     `oscInput` that capture `[weak self]` and call
//     `self?.applyParameter(...)`. Too coupled to the engine's MIDI/OSC
//     input manager instances (and through them to CoreMIDI /
//     NWListener system APIs) to extract cleanly without re-introducing
//     a weak-engine reference. See TODO(P3.13 Slice 5).
//
// `notify` is invoked in the same places the original instance method
// called `objectWillChange.send()`, so observable behavior is identical
// for UI consumers. `mixerStateUpdater` is invoked in the same places
// the original called `updateMacroMixerState()` (the `.mute` and `.solo`
// branches), preserving the post-mutation mixer refresh.
//
// White paper reference:
//   §3.3 -- Recursive formula per macro
//   §6.1 -- Black Box Resonator (each macro is one resonator)

/// Stateless owner of the parameter-routing path.
///
/// A caseless enum is used (rather than a `struct`) to make accidental
/// instantiation impossible — there is no instance state to carry.
enum ParameterRouterController {

    /// Route a `(ControlParameter, Float)` pair from MIDI CC / OSC input
    /// into the focus macro's parameter bag (and, where applicable, the
    /// internal DSP nodes that render audio) OR, when no macro is
    /// focused, into the main NodeGraph's typed nodes.
    ///
    /// - Parameters:
    ///   - param: The control parameter to route.
    ///   - value: The scaled Float value (already in the parameter's
    ///     float range — `ParameterRouter.scaleCCToValue` is applied
    ///     upstream by the MIDI/OSC managers).
    ///   - focusMacro: The currently-focused `MacroNode`, or `nil` for
    ///     flat/legacy topologies. When non-nil, the value is written
    ///     into `focusMacro.parameters[...]` (and forwarded to internal
    ///     DSP nodes for the handful of params that have a dual-write
    ///     path, e.g. `.filterCutoff` -> internal LadderFilterNode).
    ///   - crossfaderPosition: Current crossfader position 0...1.
    ///     Reserved for future use — the `.crossfader` case is handled
    ///     by the NeuralEngine delegator (scene coupling). The current
    ///     extracted paths do NOT read this value; it is accepted to
    ///     keep the helper's signature stable for Slice 5.
    ///   - nodeGraph: The main `NodeGraph`. Used as the write target
    ///     when `focusMacro` is nil (flat-topology fallback) and as the
    ///     forward target for the `.filterCutoff` -> internal ladder
    ///     dual-write.
    ///   - notify: Side-effect callback invoked in the same places the
    ///     original `NeuralEngine.objectWillChange.send()` was called,
    ///     so observable behavior is identical for UI consumers.
    ///   - mixerStateUpdater: Side-effect callback invoked in place of
    ///     the original `self.updateMacroMixerState()` calls in the
    ///     `.mute` and `.solo` branches. The NeuralEngine delegator
    ///     passes `{ self.updateMacroMixerState() }`.
    static func applyParameter(
        _ param: ControlParameter,
        value: Float,
        focusMacro: MacroNode?,
        crossfaderPosition: Float,
        nodeGraph: NodeGraph,
        notify: () -> Void,
        mixerStateUpdater: () -> Void
    ) {
        // Slice 4: the .crossfader case is NOT extracted — it mutates
        // engine state and routes through sceneManager. The NeuralEngine
        // delegator handles it before calling this helper, so we should
        // never see .crossfader here. Treat it as a no-op (the delegator
        // is the sole legitimate caller and it short-circuits .crossfader
        // before delegating). See TODO(P3.13 Slice 5).
        _ = crossfaderPosition
        if param == .crossfader {
            // TODO(P3.13 Slice 5): break scene coupling so .crossfader
            // can be extracted with crossfaderPosition as inout.
            return
        }

        guard let macro = focusMacro else {
            // Flat/legacy topologies have no MacroNode — route the
            // handful of directly-neural parameters straight to their
            // graph nodes instead of dropping them.
            applyParameterToGraphNodes(param, value: value, nodeGraph: nodeGraph)
            return
        }

        // Apply to the macro's internal graph parameters.
        // This routes control changes to the appropriate internal nodes.
        switch param {
        case .volume:
            macro.parameters["volume"] = value
        case .guidanceScale:
            macro.parameters["guidanceScale"] = value
        case .feedback:
            macro.parameters["feedbackAmount"] = value
        case .texture:
            macro.parameters["texture"] = value
        case .chaos:
            macro.parameters["chaos"] = value
        case .warmth:
            macro.parameters["warmth"] = value
        case .filterCutoff:
            macro.parameters["filterCutoff"] = value
        case .filterResonance:
            macro.parameters["filterResonance"] = value
        case .delayMix:
            macro.parameters["delayMix"] = value
        case .delayTime:
            macro.parameters["delayTime"] = value
        case .delayFeedback:
            macro.parameters["delayFeedback"] = value
        case .bitCrushDepth:
            macro.parameters["bitCrushDepth"] = value
        case .resonatorNote:
            macro.parameters["resonatorNote"] = value
        case .resonatorDecay:
            macro.parameters["resonatorDecay"] = value
        case .entropy:
            let cappedValue = value
            macro.parameters["entropyLevel"] = cappedValue
        case .granularity:
            let cappedValue = value
            macro.parameters["granularity"] = cappedValue
        case .shift:
            macro.parameters["shift"] = value
        case .inputStrength:
            macro.parameters["inputStrength"] = value
        case .inferenceSteps:
            macro.parameters["inferenceSteps"] = Int(value.rounded())
        case .sineFrequency:
            macro.parameters["sineFrequency"] = value
        case .pulseWidth:
            macro.parameters["pulseWidth"] = value
        case .lfoRate:
            macro.parameters["lfoRate"] = value
        case .lfoDepth:
            macro.parameters["lfoDepth"] = value
        case .mute:
            macro.parameters["isMuted"] = value >= 0.5
            mixerStateUpdater()
        case .solo:
            macro.parameters["isSoloed"] = value >= 0.5
            mixerStateUpdater()
        case .spectralMorphActive:
            macro.parameters["freezeActive"] = value >= 0.5
        case .inferMethodSDE:
            macro.parameters["inferMethod"] = value >= 0.5 ? "sde" : "ode"
        default:
            break
        }

        // Forward the live parameter to the concrete DSP nodes inside the
        // macro. `volume` / `mute` / `solo` are intentionally excluded — they
        // are routed through MacroMixerController (mixer state) rather than
        // direct node parameters. `crossfader` is handled by NeuralEngine.
        if param != .volume && param != .mute && param != .solo && param != .crossfader {
            forwardToDSPNodes(param, value: value, in: macro.internalGraph)
        }

        // Publish change for UI observers.
        notify()
    }

    // MARK: - DSP Forwarding

    /// Convert a MIDI note number (0-127) to frequency in Hz using the
    /// standard 440 Hz / A4 = note 69 equal-tempered formula. Used by
    /// `.resonatorNote` which is stored as a MIDI note but consumed by
    /// `TunableResonatorNode` as a Hz pitch.
    private static func midiNoteToHz(_ note: Float) -> Float {
        440.0 * powf(2.0, (note - 69.0) / 12.0)
    }

    /// Forward a live control parameter to the concrete DSP nodes that consume
    /// it inside the provided graph. Used both by the focus-macro branch
    /// (writing into `macro.internalGraph`) and by the flat-topology fallback
    /// (`nodeGraph`). Each parameter maps to a specific node type and key;
    /// non-Float values (Int, Bool, String) are written through their typed
    /// property setters so the v2.0 pull-render engine sees them on the next
    /// audio block.
    ///
    /// - Returns: `true` if at least one matching node was found and written.
    @discardableResult
    private static func forwardToDSPNodes(
        _ param: ControlParameter,
        value: Float,
        in graph: NodeGraph
    ) -> Bool {
        var written = false
        switch param {
        case .volume:
            for node in graph.nodes.values where node is MasterOutputNode {
                (node as! MasterOutputNode).volume = value
                written = true
            }
        case .guidanceScale:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).guidanceScale = value
                written = true
            }
        case .feedback:
            for node in graph.nodes.values where node is FeedbackLoopNode {
                (node as! FeedbackLoopNode).feedback = value
                written = true
            }
        case .texture:
            for node in graph.nodes.values where node is SpectralChainNode {
                (node as! SpectralChainNode).freezeBlend = value
                written = true
            }
        case .chaos:
            for node in graph.nodes.values where node is SpectralChainNode {
                (node as! SpectralChainNode).granularity = value
                written = true
            }
        case .warmth:
            for node in graph.nodes.values where node is SpectralChainNode {
                (node as! SpectralChainNode).saturationAmount = value
                written = true
            }
        case .filterCutoff:
            for node in graph.nodes.values where node is LadderFilterNode {
                (node as! LadderFilterNode).cutoff = value
                written = true
            }
        case .filterResonance:
            for node in graph.nodes.values where node is LadderFilterNode {
                (node as! LadderFilterNode).resonance = value
                written = true
            }
        case .delayMix:
            for node in graph.nodes.values where node is DelayLineNode {
                (node as! DelayLineNode).wetDryMix = value
                written = true
            }
        case .delayTime:
            for node in graph.nodes.values where node is DelayLineNode {
                (node as! DelayLineNode).delayTime = value
                written = true
            }
        case .delayFeedback:
            for node in graph.nodes.values where node is DelayLineNode {
                (node as! DelayLineNode).feedback = value
                written = true
            }
        case .bitCrushDepth:
            for node in graph.nodes.values where node is BitCrusherNode {
                (node as! BitCrusherNode).depth = value
                written = true
            }
        case .resonatorNote:
            let hz = midiNoteToHz(value)
            for node in graph.nodes.values where node is TunableResonatorNode {
                (node as! TunableResonatorNode).pitch = hz
                written = true
            }
        case .resonatorDecay:
            for node in graph.nodes.values where node is TunableResonatorNode {
                (node as! TunableResonatorNode).decay = value
                written = true
            }
        case .entropy:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).entropy = value / 100.0
                written = true
            }
        case .granularity:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).granularity = value / 100.0
                written = true
            }
        case .shift:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).shift = value
                written = true
            }
        case .inputStrength:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).inputStrength = value
                written = true
            }
        case .inferenceSteps:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).numSteps = Int(value.rounded())
                written = true
            }
        case .sineFrequency:
            for node in graph.nodes.values where node is OscillatorNode {
                (node as! OscillatorNode).frequency = value
                written = true
            }
        case .pulseWidth:
            for node in graph.nodes.values where node is OscillatorNode {
                (node as! OscillatorNode).pulseWidth = value
                written = true
            }
        case .lfoRate:
            for node in graph.nodes.values where node is AgitationNode {
                (node as! AgitationNode).updateParameter(id: "rate", value: value)
                written = true
            }
        case .lfoDepth:
            for node in graph.nodes.values where node is AgitationNode {
                (node as! AgitationNode).updateParameter(id: "depth", value: value)
                written = true
            }
        case .spectralMorphActive:
            for node in graph.nodes.values where node is SpectralChainNode {
                (node as! SpectralChainNode).freezeActive = value >= 0.5
                written = true
            }
        case .inferMethodSDE:
            for node in graph.nodes.values where node is ACEStepInferenceNode {
                (node as! ACEStepInferenceNode).inferMethod = value >= 0.5 ? "sde" : "ode"
                written = true
            }
        case .mute, .solo, .crossfader:
            // Routed via MacroMixerController (mute/solo) or NeuralEngine
            // (crossfader).
            break
        }
        return written
    }

    /// Fallback routing for MIDI CC / OSC when there's no focus macro to
    /// receive the change (flat/legacy topologies — see `applyParameter`).
    /// Routes every live control parameter to the concrete DSP node type that
    /// consumes it in the main graph; applies to every node of that type so
    /// a future topology with more than one instance still responds.
    ///
    /// SCALING NOTE: `forwardToDSPNodes` handles the 0...100 -> 0...1 rescale
    /// for `.entropy` / `.granularity` (legacy macro semantic -> ACE-Step
    /// node semantic) and the MIDI-note -> Hz conversion for `.resonatorNote`.
    static func applyParameterToGraphNodes(
        _ param: ControlParameter,
        value: Float,
        nodeGraph: NodeGraph
    ) {
        forwardToDSPNodes(param, value: value, in: nodeGraph)
    }

    /// Applies `value` to `key` on every node of type `T` in the given graph.
    static func setParameterOnNodes<T: GraphNode>(
        ofType type: T.Type,
        key: String,
        value: Float,
        nodeGraph: NodeGraph
    ) {
        for node in nodeGraph.nodes.values where node is T {
            nodeGraph.setParameter(nodeId: node.id, key: key, value: value)
        }
    }

    /// Write a parameter to a specific node, preferring `macro.internalGraph`
    /// when the node lives inside a collapsed macro and falling back to the
    /// main `nodeGraph` for expanded/legacy topologies. This mirrors the
    /// routing fix in `MacroMixerController` and `MacroLockController`.
    private static func setParameterOnNode(
        nodeId: UUID,
        key: String,
        value: Float,
        macro: MacroNode,
        nodeGraph: NodeGraph
    ) {
        if macro.internalGraph.nodes[nodeId] != nil {
            macro.internalGraph.setParameter(nodeId: nodeId, key: key, value: value)
        } else if nodeGraph.nodes[nodeId] != nil {
            nodeGraph.setParameter(nodeId: nodeId, key: key, value: value)
        }
    }
}
