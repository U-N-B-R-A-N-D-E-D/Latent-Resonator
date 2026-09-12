import Foundation

// MARK: - Parameter Lock Key

/// Identifies one parameter instance for p-lock gating.
/// Used by `SceneManager` to skip locked parameters during scene recall
/// and crossfade so they keep their current value.
struct ParameterLockKey: Hashable {
    let nodeId: UUID
    let paramId: String
}

// MARK: - Macro Lock Controller (P3.13 Surgical Slice)
//
// Stateless helper that owns the macro step-lock propagation path:
// trig gating (.skip / .oneShot / probability) plus the routing of
// per-step p-lock values into the DSP nodes that actually render audio.
//
// Extracted (behavior-preserving) from `NeuralEngine` as the first slice
// of the P3.13 "split NeuralEngine god-class" refactor. The instance
// method `NeuralEngine.applyMacroStepLocks(macro:)` now delegates here,
// and `LatentResonatorTests/ApplyMacroStepLocksTests` drives this type
// directly so the lock path can be unit-tested without instantiating
// the full `NeuralEngine` (which would mutate the system output sample
// rate and spawn the Python bridge).
//
// `notify` is invoked in the same places the original instance method
// called `objectWillChange.send()`, so observable behavior is identical.
//
// White paper reference:
//   §3.3 -- Recursive formula per macro
//   §6.1 -- Black Box Resonator (each macro is one resonator)

/// Stateless owner of the macro step-lock propagation path.
///
/// A caseless enum is used (rather than a `struct`) to make accidental
/// instantiation impossible — there is no instance state to carry.
enum MacroLockController {

    /// Apply the current step's parameter locks to one macro.
    ///
    /// - Parameters:
    ///   - macro: The `MacroNode` whose current step should be applied.
    ///   - nodeGraph: The main `NodeGraph`. Used as a fallback write
    ///     target when a node has been promoted out of `macro.internalGraph`
    ///     (expanded-macro topology); the preferred target is always
    ///     `macro.internalGraph`, which is guaranteed to hold the nodes
    ///     we iterate below.
    ///   - notify: Side-effect callback invoked in the same places the
    ///     original `NeuralEngine.objectWillChange.send()` was called,
    ///     so observable behavior is identical for UI consumers.
    static func applyMacroStepLocks(macro: MacroNode, nodeGraph: NodeGraph, notify: () -> Void) {
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        var grid = sequencer.stepGrid
        guard let step = grid.step(at: grid.currentStepIndex) else { return }

        // Trig gating — makes `.oneShot`, `.skip`, and `probability` real
        // instead of decorative (they were previously stored but never
        // consulted at runtime, so the step grid lied about its behaviour).
        //
        //   .skip     → never apply locks.
        //   .oneShot  → apply locks the first time this step is reached in
        //               the current pattern pass, then skip until the
        //               pattern wraps and `oneShotFired` clears.
        //   .note     → apply locks (subject to the probability gate).
        //   .lock     → apply locks, no probability gate (trigless by design).
        //
        // This runs on the main / sequencer thread, not the audio thread,
        // so `Float.random(in:)` is acceptable here (contrast with
        // `KoenigSeedNode.render`, which uses `Xoshiro256StarStar`).
        let stepIndex = grid.currentStepIndex
        var shouldApply: Bool
        switch step.trigType {
        case .skip:
            shouldApply = false
        case .oneShot:
            if grid.oneShotFired.contains(stepIndex) {
                shouldApply = false
            } else {
                grid.oneShotFired.insert(stepIndex)
                sequencer.stepGrid = grid   // persist transient one-shot tracking
                shouldApply = true
            }
        case .note, .lock:
            shouldApply = true
        }

        // Probability gate (only meaningful for trigs that actually fire).
        if shouldApply, step.trigType != .lock {
            if let p = step.probability, p < 1.0 {
                if Float.random(in: 0...1) > p {
                    shouldApply = false
                }
            }
        }

        guard shouldApply else {
            notify()
            return
        }

        // ── Propagate locks to the DSP nodes that actually render audio ──
        // `macro.parameters` is NOT read by any DSPNode's `render` — it is a
        // v1.x-era bag that was silently dropped by the v2.0 pull-render
        // engine. The audio thread reads `getParam(...)` on the concrete
        // `ACEStepInferenceNode` / `FeedbackLoopNode` / `LadderFilterNode` /
        // `DelayLineNode` / `BitCrusherNode` / `SpectralChainNode` instances
        // living inside `macro.internalGraph`. Writing locks anywhere else
        // is a no-op that lies to the UI (knob moves, nothing changes in the
        // mix). Each setter below is guarded by `as? <NodeType>` so a macro
        // whose preset omits a given stage skips that lock silently — no
        // crash, no spurious mutation. No rebuild-notification step is
        // needed after `nodeGraph.setParameter`: the audio thread reads
        // these same node instances' parameters fresh via `getParam` on
        // its next render block (eventual-consistent by design —
        // perimeter audit, 2026-07-21).
        let internalGraph = macro.internalGraph

        // P3.13: route p-lock writes to the graph that actually owns the
        // target node. Internal DSP nodes live in `macro.internalGraph`;
        // when the macro is EXPANDED they are also promoted to the main
        // `nodeGraph` as the same class reference, so writing to either
        // reaches the same underlying object. When the macro is COLLAPSED
        // the node is ONLY in `internalGraph`, so the previous call
        // `nodeGraph.setParameter(nodeId: <internal-id>, ...)` was a silent
        // no-op (`setParameter`'s `guard var node = nodes[nodeId] else { return }`
        // missed) — the knob moved on screen, the audio thread never heard
        // the change. We prefer `internalGraph` (always present for the
        // nodes we iterate below) and fall back to `nodeGraph` for safety.
        @inline(__always) func setLock(on nodeId: UUID, key: String, value: Float) {
            if internalGraph.nodes[nodeId] != nil {
                internalGraph.setParameter(nodeId: nodeId, key: key, value: value)
            } else {
                nodeGraph.setParameter(nodeId: nodeId, key: key, value: value)
            }
        }

        if let v = step.cfg {
            let clamped = min(max(v, LRConstants.cfgScaleRange.lowerBound),
                              LRConstants.cfgScaleRange.upperBound)
            macro.parameters["guidanceScale"] = clamped
            for node in internalGraph.nodes.values {
                if let ace = node as? ACEStepInferenceNode {
                    setLock(on: ace.id, key: "guidanceScale", value: clamped)
                }
            }
        }
        if let v = step.feedback {
            let clamped = min(max(v, 0), 1)
            macro.parameters["feedbackAmount"] = clamped
            for node in internalGraph.nodes.values {
                if let loop = node as? FeedbackLoopNode {
                    setLock(on: loop.id, key: "feedback", value: clamped)
                }
            }
        }
        if let phase = step.promptPhase {
            macro.parameters["promptPhaseOverride"] = min(max(phase, 1), 3)
            // No DSP node reads promptPhaseOverride directly; PromptEngineNode
            // phase selection is driven by spectral flatness, not step locks.
        }

        // DSP / macro locks — routed to the concrete effect nodes that
        // actually read these param keys in `render`.
        if let v = step.texture {
            let clamped = min(max(v, 0), 1)
            macro.parameters["texture"] = clamped
            for node in internalGraph.nodes.values {
                if let spec = node as? SpectralChainNode {
                    setLock(on: spec.id, key: "freezeBlend", value: clamped)
                }
            }
        }
        if let v = step.chaos {
            let clamped = min(max(v, 0), 1)
            macro.parameters["chaos"] = clamped
            for node in internalGraph.nodes.values {
                if let spec = node as? SpectralChainNode {
                    setLock(on: spec.id, key: "granularity", value: clamped)
                }
            }
        }
        if let v = step.warmth {
            let clamped = min(max(v, 0), 1)
            macro.parameters["warmth"] = clamped
            for node in internalGraph.nodes.values {
                if let spec = node as? SpectralChainNode {
                    setLock(on: spec.id, key: "saturationAmount", value: clamped)
                }
            }
        }
        if let v = step.filterCutoff {
            let clamped = min(max(v, LRConstants.filterCutoffRange.lowerBound),
                              LRConstants.filterCutoffRange.upperBound)
            macro.parameters["filterCutoff"] = clamped
            for node in internalGraph.nodes.values {
                if let ladder = node as? LadderFilterNode {
                    setLock(on: ladder.id, key: "cutoff", value: clamped)
                }
            }
        }
        if let v = step.filterResonance {
            let clamped = min(max(v, LRConstants.filterResonanceRange.lowerBound),
                              LRConstants.filterResonanceRange.upperBound)
            macro.parameters["filterResonance"] = clamped
            for node in internalGraph.nodes.values {
                if let ladder = node as? LadderFilterNode {
                    setLock(on: ladder.id, key: "resonance", value: clamped)
                }
            }
        }
        if let v = step.excitationMode {
            macro.parameters["excitationMode"] = v
            // Excitation mode is consumed by OscillatorNode at the macro
            // level (waveform switch); routed via the macro parameter bag
            // which `applyExcitation`-style UI paths already read.
        }
        if let v = step.delayMix {
            let clamped = min(max(v, 0), 1)
            macro.parameters["delayMix"] = clamped
            for node in internalGraph.nodes.values {
                if let delay = node as? DelayLineNode {
                    setLock(on: delay.id, key: "wetDryMix", value: clamped)
                }
            }
        }
        if let v = step.bitCrushDepth {
            let clamped = min(max(v, LRConstants.bitCrushRange.lowerBound),
                              LRConstants.bitCrushRange.upperBound)
            macro.parameters["bitCrushDepth"] = clamped
            for node in internalGraph.nodes.values {
                if let crusher = node as? BitCrusherNode {
                    setLock(on: crusher.id, key: "depth", value: clamped)
                }
            }
        }

        // Generic locks (Wave C C2): any manually exposed Float control can be
        // p-locked by ExposedControl.id. The value is clamped to the control's
        // range and written to whichever graph actually owns the target node.
        for (controlId, value) in step.genericLocks {
            guard let control = nodeGraph.exposedControls.first(where: { $0.id == controlId }) else { continue }
            let clamped = min(max(value, control.range.lowerBound), control.range.upperBound)
            setLock(on: control.nodeId, key: control.paramId, value: clamped)
        }

        // Trig behavior
        if step.trigType == .lock {
            // DSP-only mode for next cycle. MacroNode is now a DSPNode
            // (Fix 4a closed — see MacroNode.render / ExecutionPlan.build),
            // so its `render` walks the cached internal plan; this flag
            // remains on the parameter bag for UI introspection and any
            // future per-macro DSP gating.
            macro.parameters["dspOnlyForNextCycle"] = true
        }

        // Publish changes
        notify()
    }

    // MARK: - Locked Parameter Key Query (Wave C p-lock gating)

    /// Returns the set of parameter keys that the active step currently locks.
    /// This mirrors the exact write targets used by `applyMacroStepLocks` so
    /// `SceneManager` can skip those parameters during scene recall/crossfade.
    static func lockedParameterKeys(
        for step: PerformanceStep,
        macro: MacroNode,
        exposedControls: [ExposedControl]
    ) -> Set<ParameterLockKey> {
        var keys = Set<ParameterLockKey>()

        /// Helper to add a macro-level parameter key (the bag that some UI
        /// paths and parameter routers read from the parent macro node).
        func addMacroParam(_ paramId: String) {
            keys.insert(ParameterLockKey(nodeId: macro.id, paramId: paramId))
        }

        // Generic locks: look up the exposed control to get the real target.
        for (controlId, _) in step.genericLocks {
            guard let control = exposedControls.first(where: { $0.id == controlId }) else { continue }
            keys.insert(ParameterLockKey(nodeId: control.nodeId, paramId: control.paramId))
        }

        // Legacy locks mapped to the same DSP nodes this controller writes.
        if step.cfg != nil {
            addMacroParam("guidanceScale")
            for node in macro.internalGraph.nodes.values {
                if node is ACEStepInferenceNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "guidanceScale"))
                }
            }
        }
        if step.feedback != nil {
            addMacroParam("feedbackAmount")
            for node in macro.internalGraph.nodes.values {
                if node is FeedbackLoopNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "feedback"))
                }
            }
        }
        if step.texture != nil {
            addMacroParam("texture")
            for node in macro.internalGraph.nodes.values {
                if node is SpectralChainNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "freezeBlend"))
                }
            }
        }
        if step.chaos != nil {
            addMacroParam("chaos")
            for node in macro.internalGraph.nodes.values {
                if node is SpectralChainNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "granularity"))
                }
            }
        }
        if step.warmth != nil {
            addMacroParam("warmth")
            for node in macro.internalGraph.nodes.values {
                if node is SpectralChainNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "saturationAmount"))
                }
            }
        }
        if step.filterCutoff != nil {
            addMacroParam("filterCutoff")
            for node in macro.internalGraph.nodes.values {
                if node is LadderFilterNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "cutoff"))
                }
            }
        }
        if step.filterResonance != nil {
            addMacroParam("filterResonance")
            for node in macro.internalGraph.nodes.values {
                if node is LadderFilterNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "resonance"))
                }
            }
        }
        if step.excitationMode != nil {
            addMacroParam("excitationMode")
        }
        if step.delayMix != nil {
            addMacroParam("delayMix")
            for node in macro.internalGraph.nodes.values {
                if node is DelayLineNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "wetDryMix"))
                }
            }
        }
        if step.bitCrushDepth != nil {
            addMacroParam("bitCrushDepth")
            for node in macro.internalGraph.nodes.values {
                if node is BitCrusherNode {
                    keys.insert(ParameterLockKey(nodeId: node.id, paramId: "depth"))
                }
            }
        }

        return keys
    }
}
