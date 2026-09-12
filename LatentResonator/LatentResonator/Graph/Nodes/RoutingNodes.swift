import Foundation
import AVFoundation
import Combine

// MARK: - Mixer Node

/// Multi-input mixer with per-input gain and a master output gain.
/// Sums up to `MixerNode.maxInputs` stereo inputs into one stereo output.
final class MixerNode: BaseGraphNode {

    /// Hard upper bound on simultaneous audio inputs. Matches the four
    /// per-input gain knobs (`gain1`…`gain4`) exposed in the PatchEditor
    /// and the saved-patch wire format.
    static let maxInputs: Int = 4

    // MARK: - Parameters

    /// Master output gain — applied after summing inputs.
    /// PatchEditor uses `masterGain`; we accept the legacy `outputGain` key
    /// as a fallback so older patches keep working.
    var masterGain: Float {
        get {
            if let v = parameters["masterGain"] as? Float { return v }
            if let v = parameters["outputGain"] as? Float { return v }
            return 1.0
        }
        set { setParam("masterGain", value: newValue) }
    }

    /// Per-input gains, indexed 1..maxInputs. Stored as `gain1`…`gain4`.
    func inputGain(_ index1Based: Int) -> Float {
        return getParam("gain\(index1Based)", default: 1.0)
    }

    // MARK: - Internal State

    private var inputCount: Int = 0

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "mixer",
            category: .routing,
            displayName: "MIXER"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        var p: [NodePort] = []

        // Stable input port ids (`in1`…`in4`) match the saved-patch
        // `targetPortId` strings used by the PatchEditor.
        for i in 1...MixerNode.maxInputs {
            p.append(NodePort(
                id: "in\(i)",
                label: "IN \(i)",
                signalType: .audio,
                direction: .input
            ))
        }

        p.append(NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output))
        p.append(NodePort(id: "gain_cv", label: "GAIN CV", signalType: .control, direction: .input))

        return p
    }

    // MARK: - Topology

    func onTopologyChanged(inputs: [String: GraphEdge], outputs: [String: [GraphEdge]]) {
        let audioInputs = inputs.values.filter { $0.signalType == .audio }
        inputCount = audioInputs.count
    }
}

// MARK: - MixerNode + DSPNode

extension MixerNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // P1.5 — snapshot every per-input gain + master into locals before
        // the sum loop. `inputGain(k)` calls `getParam` (COW dict read); a
        // knob drag mid-block would otherwise force a heap alloc per
        // iteration on the audio thread. Fixed-size locals — no array
        // allocation, maxInputs is a compile-time 4.
        let g1 = inputGain(1)
        let g2 = inputGain(2)
        let g3 = inputGain(3)
        let g4 = inputGain(4)
        let master = masterGain

        // Zero the output before accumulating
        let bytes = frameCount * MemoryLayout<Float>.stride
        memset(output.left, 0, bytes)
        memset(output.right, 0, bytes)

        let count = min(inputs.count, MixerNode.maxInputs)
        for k in 0..<count {
            // Plan builder sorts inputs by target port id ("in1" < "in2" < …),
            // so input index k maps to gain index k+1 (gain1, gain2, …).
            let g: Float
            switch k {
            case 0: g = g1
            case 1: g = g2
            case 2: g = g3
            case 3: g = g4
            default: g = 0
            }
            let inBuf = inputs[k]
            for i in 0..<frameCount {
                output.left[i]  += inBuf.left[i]  * g
                output.right[i] += inBuf.right[i] * g
            }
        }

        if master != 1.0 {
            for i in 0..<frameCount {
                output.left[i] *= master
                output.right[i] *= master
            }
        }
    }
}

// MARK: - Master Output Node

/// Terminal node of the audio graph. Receives one stereo input, applies a
/// master volume, and writes the result into the engine's ABL.
///
/// In the new pull-render `GraphAudioEngine`, MasterOutput is special: the
/// `ExecutionPlan` builder marks it as the terminal step so its `render`
/// output goes directly to the AVAudioSourceNode buffer — never through
/// the `BufferPool`.
final class MasterOutputNode: BaseGraphNode {

    // MARK: - Parameters

    var volume: Float {
        get { getParam("volume", default: 1.0) }
        set { setParam("volume", value: newValue) }
    }

    /// Soft-clip threshold. Currently informational — applied as a hard
    /// safety ceiling in `render(...)` so a runaway feedback loop can
    /// never blow past `volume` × `limiterThreshold` linear.
    var limiterThreshold: Float {
        get { getParam("limiterThreshold", default: -0.1) }
        set { setParam("limiterThreshold", value: newValue) }
    }

    // MARK: - Init

    init(id: UUID = UUID(), name: String = "Master Out", x: Double = 0, y: Double = 0) {
        super.init(
            id: id,
            nodeType: "master_output",
            category: .routing,
            displayName: name,
            x: x,
            y: y
        )

        setParam("volume", value: Float(1.0))
        setParam("limiterThreshold", value: Float(-0.1))
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input)
        ]
    }
}

// MARK: - MasterOutputNode + DSPNode

extension MasterOutputNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        let v = volume

        guard let inBuf = inputs.first else {
            // No input wired into master — emit silence rather than leak
            // whatever was previously in the ABL.
            let bytes = frameCount * MemoryLayout<Float>.stride
            memset(output.left, 0, bytes)
            memset(output.right, 0, bytes)
            return
        }

        // Hard safety ceiling derived from `limiterThreshold` (stored in dB).
        // `limiterThreshold = -0.1 dB` → linear ceiling ≈ 0.988.
        let ceiling = powf(10.0, limiterThreshold / 20.0)

        for i in 0..<frameCount {
            var l = inBuf.left[i] * v
            var r = inBuf.right[i] * v
            if l > ceiling { l = ceiling } else if l < -ceiling { l = -ceiling }
            if r > ceiling { r = ceiling } else if r < -ceiling { r = -ceiling }
            output.left[i] = l
            output.right[i] = r
        }
    }
}

// MARK: - Passthrough Node

/// Identity transform for testing graph connectivity.
/// Passes audio through unmodified.
final class PassthroughNode: BaseGraphNode {
    
    // MARK: - Internal State
    
    private var mixerUnit: AVAudioMixerNode
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        self.mixerUnit = AVAudioMixerNode()
        
        super.init(
            id: id,
            nodeType: "passthrough",
            category: .routing,
            displayName: "PASSTHROUGH"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        mixerUnit.outputVolume = 1.0
    }
    
    required init(from decoder: Decoder) throws {
        self.mixerUnit = AVAudioMixerNode()
        try super.init(from: decoder)
        mixerUnit.outputVolume = 1.0
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return mixerUnit
    }
}

// MARK: - Silence Node

/// Null source forcing pure latent hallucination.
/// Outputs zeros (no excitation).
final class SilenceNode: BaseGraphNode {
    
    // MARK: - Internal State
    
    private var sourceNode: AVAudioSourceNode?
    private let format: AVAudioFormat
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        let fmt = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        self.format = fmt
        
        super.init(
            id: id,
            nodeType: "silence",
            category: .source,
            displayName: "SILENCE"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        try super.init(from: decoder)
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            
            for buffer in ablPointer {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            
            return noErr
        }
    }
}
