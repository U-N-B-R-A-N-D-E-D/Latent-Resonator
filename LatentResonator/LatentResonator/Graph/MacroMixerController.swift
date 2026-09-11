import Foundation

// MARK: - Macro Mixer Controller (P3.13 Surgical Slice 2)
//
// Stateless helper that owns the macro-mixer state propagation path:
// routing each macro's `volume` / `isMuted` / `isSoloed` parameter bag
// values onto the DSP nodes that actually render audio — the macro's
// internal `MixerNode.masterGain` (primary path) or, when no internal
// mixer exists, the `OscillatorNode` / `NoiseNode` source amplitudes
// (fallback path).
//
// Extracted (behavior-preserving) from `NeuralEngine.updateMacroMixerState`
// as the second slice of the P3.13 "split NeuralEngine god-class" refactor.
// The instance methods `NeuralEngine.updateMacroMixerState()` and
// `NeuralEngine.updateLaneMixerState()` now delegate here, and
// `LatentResonatorTests/MacroMixerControllerTests` drives this type
// directly so the mixer path can be unit-tested without instantiating
// the full `NeuralEngine` (which would mutate the system output sample
// rate and spawn the Python bridge).
//
// `notify` is invoked once at completion of each code path. The original
// `updateMacroMixerState` had NO explicit `objectWillChange.send()` call;
// its UI refresh side effect came from `nodeGraph.setParameter`'s
// internal `objectWillChange.send()`. The extracted helper preserves
// that implicit side effect (by taking `nodeGraph` and calling
// `setParameter` on it verbatim) and adds one idempotent `notify()` call
// at completion for API symmetry with `MacroLockController` — an extra
// `objectWillChange.send()` is harmless under Combine.
//
// ROUTING (P3.13 Slice 3 — collapsed-macro fix):
//   All `setParameter` writes route through a local `setParam(on:key:value:)`
//   closure that prefers `macro.internalGraph.setParameter(...)` and falls
// back to the main `nodeGraph.setParameter(...)`. This mirrors the
// `MacroLockController.setLock` pattern: when the macro is COLLAPSED the
// target DSP node lives only in `macro.internalGraph`, so a direct
// `nodeGraph.setParameter(nodeId: <internal-id>, ...)` was a silent no-op
// (`setParameter`'s `guard var node = nodes[nodeId] else { return }` missed)
// — the knob moved on screen, the audio thread never heard the change.
// Preferring `internalGraph` (always present for the nodes we touch below)
// closes that gap for both the MixerNode masterGain path and the
// source-amplitude fallback path.
//
// White paper reference:
//   §3.3 -- Recursive formula per macro
//   §6.1 -- Black Box Resonator (each macro is one resonator)

/// Stateless owner of the macro-mixer state propagation path.
///
/// A caseless enum is used (rather than a `struct`) to make accidental
/// instantiation impossible — there is no instance state to carry.
enum MacroMixerController {

    /// Apply volume / mute / solo logic to a single macro.
    ///
    /// - Parameters:
    ///   - macro: The `MacroNode` whose mixer state should be updated.
    ///   - nodeGraph: The main `NodeGraph`. Used both to compute
    ///     `anySoloed` across all macros and as a fallback write target
    ///     for `setParameter`. Writes prefer `macro.internalGraph`
    ///     (which always holds the internal DSP nodes we touch) and
    ///     fall back to `nodeGraph` — see the ROUTING note in the file
    ///     header.
    ///   - notify: Side-effect callback invoked once at completion. The
    ///     NeuralEngine delegator passes `{ self.objectWillChange.send() }`
    ///     so UI consumers refresh exactly as before.
    static func updateMacroMixerState(macro: MacroNode, nodeGraph: NodeGraph, notify: () -> Void) {
        let anySoloed = nodeGraph.nodes.values
            .compactMap { $0 as? MacroNode }
            .contains(where: { $0.parameters["isSoloed"] as? Bool ?? false })

        let isMuted = macro.parameters["isMuted"] as? Bool ?? false
        let isSoloed = macro.parameters["isSoloed"] as? Bool ?? false
        let volume = macro.parameters["volume"] as? Float ?? 1.0

        let effectiveVolume: Float
        if isMuted {
            effectiveVolume = 0.0
        } else if anySoloed {
            effectiveVolume = isSoloed ? volume : 0.0
        } else {
            effectiveVolume = volume
        }

        // P3.13 Slice 3: route writes to the graph that actually owns the
        // target node. Internal DSP nodes (MixerNode / OscillatorNode /
        // NoiseNode) live in `macro.internalGraph`; when the macro is
        // EXPANDED they are also promoted to the main `nodeGraph` as the
        // same class reference, so writing to either reaches the same
        // underlying object. When the macro is COLLAPSED the node is ONLY
        // in `internalGraph`, so the previous call
        // `nodeGraph.setParameter(nodeId: <internal-id>, ...)` was a
        // silent no-op (`setParameter`'s `guard var node = nodes[nodeId]
        // else { return }` missed) — the knob moved on screen, the audio
        // thread never heard the change. We prefer `internalGraph`
        // (always present for the nodes we touch below) and fall back to
        // `nodeGraph` for safety. Same fix MacroLockController applied to
        // step-locks.
        let internalGraph = macro.internalGraph
        @inline(__always) func setParam(on nodeId: UUID, key: String, value: Float) {
            if internalGraph.nodes[nodeId] != nil {
                internalGraph.setParameter(nodeId: nodeId, key: key, value: value)
            } else {
                nodeGraph.setParameter(nodeId: nodeId, key: key, value: value)
            }
        }

        // Primary path: the macro's internal MixerNode. Its `render`
        // reads `masterGain` (RoutingNodes.swift), so writing here is
        // what actually scales the macro's audio output.
        if let mixerNodeId = macro.parameters["mixerNodeId"] as? String,
           let uuid = UUID(uuidString: mixerNodeId),
           macro.internalGraph.nodes[uuid] != nil {
            setParam(on: uuid, key: "masterGain", value: effectiveVolume)
            notify()
            return
        }

        // Lookup-by-type fallback for macros built via `fromPreset`,
        // which never recorded the mixer id. First internal MixerNode
        // wins (presets ship exactly one).
        if let internalMixer = macro.internalGraph.nodes.values
            .compactMap({ $0 as? MixerNode })
            .first {
            setParam(on: internalMixer.id, key: "masterGain", value: effectiveVolume)
            notify()
            return
        }

        // Last-resort fallback: no internal mixer at all. Scale each
        // source amplitude individually so mute/solo still silences the macro.
        // We cache each source's authored amplitude under a per-node key so
        // subsequent calls can restore the original value when the user
        // un-mutes — without this cache, un-muting would leave the source
        // stuck at whatever the last effectiveVolume was.
        for node in macro.internalGraph.nodes.values {
            if let osc = node as? OscillatorNode {
                let baseKey = "baseSourceAmplitude_\(osc.id.uuidString)"
                let base = (macro.parameters[baseKey] as? Float) ?? osc.amplitude
                if macro.parameters[baseKey] == nil {
                    macro.parameters[baseKey] = base
                }
                setParam(on: osc.id, key: "amplitude", value: base * effectiveVolume)
            } else if let noise = node as? NoiseNode {
                let baseKey = "baseSourceAmplitude_\(noise.id.uuidString)"
                let base = (macro.parameters[baseKey] as? Float) ?? noise.amplitude
                if macro.parameters[baseKey] == nil {
                    macro.parameters[baseKey] = base
                }
                setParam(on: noise.id, key: "amplitude", value: base * effectiveVolume)
            }
        }
        notify()
    }
}
