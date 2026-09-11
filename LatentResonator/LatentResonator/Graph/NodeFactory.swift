import Foundation
import AVFoundation

// MARK: - Node Factory
//
// Extracted (behavior-preserving) from `NodeGraph.swift` as part of the
// P3.13 "NodeGraph.swift vertedero cleanup" refactor. `NodeFactory` is a
// caseless enum used as a namespace for the static `createNode` switch —
// it has no instance state and closes over no `NodeGraph` private state,
// so it lifts out cleanly with no access-level changes and no behavior
// change. Callers (`NodeGraph.addNode` / `NodeGraph.deserialize`) continue
// to invoke `NodeFactory.createNode(...)` exactly as before; Swift resolves
// the type at module scope across files in the same target.

/// Factory for creating nodes from type strings.
/// Extended as new node types are implemented.
enum NodeFactory {
    static func createNode(
        id: UUID,
        type: String,
        params: [String: Any],
        mainMixer: AVAudioMixerNode? = nil,
        inputNode: AVAudioInputNode? = nil,
        bridge: ACEStepBridge? = nil,
        audioInputBuffer: CircularAudioBuffer? = nil
    ) -> (any GraphNode)? {
        switch type {
        case "oscillator":
            return OscillatorNode(id: id, params: params)
        case "koenig_seed":
            return KoenigSeedNode(id: id, params: params)
        case "markov_sequencer":
            return MarkovSequencerNode(id: id, params: params)
        case "gesture_recorder":
            return GestureRecorderNode(id: id, params: params)
        case "noise":
            return NoiseNode(id: id, params: params)
        case "silence":
            return SilenceNode(id: id, params: params)
        case "audio_input":
            return AudioInputNode(
                id: id,
                params: params,
                engineInputNode: inputNode,
                audioInputBuffer: audioInputBuffer
            )
        case "mixer":
            return MixerNode(id: id, params: params)
        case "master_output":
            let name = params["displayName"] as? String ?? "Master Out"
            let x = params["x"] as? Double ?? 0
            let y = params["y"] as? Double ?? 0
            let node = MasterOutputNode(id: id, name: name, x: x, y: y)
            // Copy any volume/threshold params
            if let volume = params["volume"] as? Float {
                node.setParam("volume", value: volume)
            }
            if let threshold = params["limiterThreshold"] as? Float {
                node.setParam("limiterThreshold", value: threshold)
            }
            return node
        case "passthrough":
            return PassthroughNode(id: id, params: params)
        // The 8 per-stage spectral nodes (FFT/SemEQ/Sat/Noise/Mem/Gran/Freeze/IFFT)
        // were a v1.x API replaced by `SpectralChainNode` (the single "Spectra"
        // stage per ROAD_TO_V2_UX §3.1). They are intentionally NOT registered
        // here — instantiating them on the canvas would fragment the Spectra
        // stage into 8 sub-nodes and produce silence (they don't conform to
        // DSPNode, so ExecutionPlan.build skips them). Their class definitions
        // remain in SpectralNodes.swift as the spectral-operation library
        // SpectralPipeline stages build on.
        case "ladder_filter":
            return LadderFilterNode(id: id, params: params)
        case "comb_filter":
            return CombFilterNode(id: id, params: params)
        case "tunable_resonator":
            return TunableResonatorNode(id: id, params: params)
        case "bit_crusher":
            return BitCrusherNode(id: id, params: params)
        case "waveshaper":
            return WaveshaperNode(id: id, params: params)
        case "delay_line":
            return DelayLineNode(id: id, params: params)
        case "ace_step_inference":
            return ACEStepInferenceNode(id: id, params: params, bridge: bridge)
        case "prompt_engine":
            return PromptEngineNode(id: id, params: params)
        case "prompt_bank":
            return PromptBankNode(id: id)
        case "macro":
            // Try complex deserialization first (for saved graphs with full macro data)
            if let name = params["name"] as? String,
               let _ = params["internalGraph"] as? [String: Any],
               let exposedPortsData = params["exposedPorts"] as? [[String: Any]],
               let portMappingsData = params["portMappings"] as? [String: [String: String]] {

                let internalGraph = NodeGraph(autoSaveEnabled: false)
                let exposedPorts = exposedPortsData.compactMap { portData -> NodePort? in
                    guard let id = portData["id"] as? String,
                          let label = portData["label"] as? String,
                          let signalTypeRaw = portData["signalType"] as? String,
                          let directionRaw = portData["direction"] as? String,
                          let signalType = SignalType(rawValue: signalTypeRaw),
                          let direction = PortDirection(rawValue: directionRaw) else {
                        return nil
                    }
                    return NodePort(id: id, label: label, signalType: signalType, direction: direction)
                }
                
                var portMappings: [String: (nodeId: UUID, portId: String)] = [:]
                for (externalPortId, mapping) in portMappingsData {
                    guard let nodeIdString = mapping["nodeId"],
                          let nodeId = UUID(uuidString: nodeIdString),
                          let portId = mapping["portId"] else {
                        continue
                    }
                    portMappings[externalPortId] = (nodeId, portId)
                }
                
                return MacroNode(
                    id: id,
                    name: name,
                    internalGraph: internalGraph,
                    exposedPorts: exposedPorts,
                    portMappings: portMappings
                )
            }
            // Fallback to simple deserialization (uses MacroNode's convenience init)
            return MacroNode(id: id, params: params)
        case "feedback_loop":
            return FeedbackLoopNode(id: id, params: params, bridge: bridge)
        case "agitation":
            return AgitationNode(id: id, params: params)
        case "peak":
            return PeakNode(id: id, params: params)
        case "manual_control":
            return ManualControlNode(id: id, params: params)
        case "meta_parameter":
            return MetaParameterNode(id: id, params: params)
        case "step_sequencer":
            return SequencerNode(id: id, params: params)
        case "spectral_analyzer":
            return SpectralAnalyzerNode(id: id, params: params)
        case "spectral_chain":
            return SpectralChainNode(id: id, params: params)
        case "spectral_feedback":
            return SpectralFeedbackNode(id: id, params: params)
        case "reverb":
            return ReverbNode(id: id, params: params)
        default:
            return nil
        }
    }
}
