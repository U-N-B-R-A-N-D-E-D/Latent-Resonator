import Foundation
import AVFoundation
import Combine

// MARK: - Mixer Node

/// Multi-input mixer with dynamic input count.
/// Wraps AVAudioMixerNode.
final class MixerNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var outputGain: Float {
        get { getParam("outputGain", default: 1.0) }
        set { setParam("outputGain", value: newValue) }
    }
    
    // MARK: - Internal State
    
    private let mixerUnit: AVAudioMixerNode
    private var inputCount: Int = 0
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        self.mixerUnit = AVAudioMixerNode()
        
        super.init(
            id: id,
            nodeType: "mixer",
            category: .routing,
            displayName: "MIXER"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        mixerUnit.outputVolume = outputGain
    }
    
    required init(from decoder: Decoder) throws {
        self.mixerUnit = AVAudioMixerNode()
        try super.init(from: decoder)
        mixerUnit.outputVolume = outputGain
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        var p: [NodePort] = []
        
        // Dynamic input ports based on connections
        for i in 0..<max(inputCount, 4) {
            p.append(NodePort(
                id: "in\(i)",
                label: "IN \(i+1)",
                signalType: .audio,
                direction: .input
            ))
        }
        
        p.append(NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output))
        p.append(NodePort(id: "gain_cv", label: "GAIN CV", signalType: .control, direction: .input))
        
        return p
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return mixerUnit
    }
    
    // MARK: - Topology
    
    func onTopologyChanged(inputs: [String: GraphEdge], outputs: [String: [GraphEdge]]) {
        // Count audio inputs (excluding gain_cv)
        let audioInputs = inputs.values.filter { $0.signalType == .audio }
        inputCount = audioInputs.count
        
        // Update mixer gain if changed
        mixerUnit.outputVolume = outputGain
    }
}

// MARK: - Master Output Node

/// Final output node routing to the system audio device.
/// Owns its own mixer node for proper audio unit lifecycle management.
final class MasterOutputNode: BaseGraphNode {

    // MARK: - Parameters

    var volume: Float {
        get { getParam("volume", default: 1.0) }
        set { setParam("volume", value: newValue) }
    }

    var limiterThreshold: Float {
        get { getParam("limiterThreshold", default: -0.1) }
        set { setParam("limiterThreshold", value: newValue) }
    }

    // MARK: - Internal State

    /// Owned mixer node - strong reference ensures audio unit lifecycle
    private let mixer = AVAudioMixerNode()

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

        // Set default parameter values
        setParam("volume", value: Float(1.0))
        setParam("limiterThreshold", value: Float(-0.1))

        mixer.outputVolume = volume
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        mixer.outputVolume = volume
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input)
        ]
    }

    // MARK: - Audio Unit

    override func audioUnit() -> AVAudioNode? {
        return mixer
    }

    // MARK: - Topology

    func onTopologyChanged(inputs: [String: GraphEdge], outputs: [String: [GraphEdge]]) {
        mixer.outputVolume = volume
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
