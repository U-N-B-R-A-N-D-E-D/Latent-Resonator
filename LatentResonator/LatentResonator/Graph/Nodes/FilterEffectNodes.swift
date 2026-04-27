import Foundation
import AVFoundation
import Accelerate

// MARK: - Ladder Filter Node

/// 4-pole Moog-style ladder filter with self-resonance.
/// Zavalishin TPT (topology-preserving transform) implementation.
final class LadderFilterNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var cutoff: Float {
        get { getParam("cutoff", default: LRConstants.filterCutoffDefault) }
        set { setParam("cutoff", value: newValue) }
    }
    
    var resonance: Float {
        get { getParam("resonance", default: LRConstants.filterResonanceDefault) }
        set { setParam("resonance", value: newValue) }
    }
    
    var mode: FilterMode {
        get { getParam("mode", default: .lowpass) }
        set { setParam("mode", value: newValue) }
    }
    
    // MARK: - State

    /// Independent ladder state per channel — true stereo. Sharing state
    /// across channels would couple their decay characteristics and lose
    /// the stereo image of the input signal.
    private var ladderStageL: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var ladderStageR: (Float, Float, Float, Float) = (0, 0, 0, 0)

    // MARK: - Smoothing

    private var smoothedCutoff: Float = LRConstants.filterCutoffDefault
    private var smoothedResonance: Float = LRConstants.filterResonanceDefault

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "ladder_filter",
            category: .effect,
            displayName: "LADDER FILTER"
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
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "cutoff_cv", label: "CUTOFF CV", signalType: .control, direction: .input),
            NodePort(id: "res_cv", label: "RES CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Processing

    /// Single-channel TPT ladder filter (Zavalishin §4). The state tuple is
    /// passed `inout` so the `render` method can hold separate state per
    /// channel without duplicating the inner DSP loop.
    @inline(__always)
    fileprivate func processChannel(
        _ data: UnsafeMutablePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        gComp: Float,
        feedbackK: Float,
        state: inout (Float, Float, Float, Float),
        mode: FilterMode
    ) {
        var s0 = state.0
        var s1 = state.1
        var s2 = state.2
        var s3 = state.3

        for i in 0..<frameCount {
            let input = data[i]
            let feedback = input - feedbackK * s3

            let v0 = gComp * (feedback - s0)
            let t0 = v0 + s0
            s0 = t0 + v0

            let v1 = gComp * (t0 - s1)
            let t1 = v1 + s1
            s1 = t1 + v1

            let v2 = gComp * (t1 - s2)
            let t2 = v2 + s2
            s2 = t2 + v2

            let v3 = gComp * (t2 - s3)
            let t3 = v3 + s3
            s3 = t3 + v3

            switch mode {
            case .lowpass:
                data[i] = t3
            case .highpass:
                data[i] = input - t3
            case .bandpass:
                data[i] = t1 - t3
            }
        }

        state = (s0, s1, s2, s3)
    }
}

// MARK: - LadderFilterNode + DSPNode

extension LadderFilterNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        // 1-pole parameter smoothing (slide~ equivalent)
        let alpha: Float = 0.05
        smoothedCutoff += alpha * (cutoff - smoothedCutoff)
        smoothedResonance += alpha * (resonance - smoothedResonance)

        // No input → emit silence. (Would happen if the user disconnects
        // the input cable; we don't want to filter the previous buffer
        // forever.)
        guard let inputBuffer = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        // Copy input into output, then run the filter in-place on the
        // output buffers. Two channels, two states.
        for i in 0..<frameCount {
            output.left[i] = inputBuffer.left[i]
            output.right[i] = inputBuffer.right[i]
        }

        // Bypass: filter wide open and no resonance — pass through unchanged.
        if smoothedCutoff >= 19900.0 && smoothedResonance < 0.01 {
            return
        }

        // TPT coefficients (computed once per render block)
        let sr = Float(sampleRate)
        let g = tanf(.pi * min(smoothedCutoff, sr * 0.49) / sr)
        let gComp = g / (1.0 + g)
        let k = 4.0 * smoothedResonance
        let m = mode

        processChannel(
            output.left,
            frameCount: frameCount,
            sampleRate: sampleRate,
            gComp: gComp,
            feedbackK: k,
            state: &ladderStageL,
            mode: m
        )
        processChannel(
            output.right,
            frameCount: frameCount,
            sampleRate: sampleRate,
            gComp: gComp,
            feedbackK: k,
            state: &ladderStageR,
            mode: m
        )
    }

    func reset() {
        ladderStageL = (0, 0, 0, 0)
        ladderStageR = (0, 0, 0, 0)
        smoothedCutoff = cutoff
        smoothedResonance = resonance
    }
}

// MARK: - Comb Filter Node

/// Parallel comb filters with prime-number delay spacing.
/// Creates inharmonic "Metallic Sheen" artifact.
final class CombFilterNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var feedback: Float {
        get { getParam("feedback", default: 0.5) }
        set { setParam("feedback", value: newValue) }
    }
    
    var baseDelay: Int {
        get { getParam("baseDelay", default: 127) }
        set { setParam("baseDelay", value: newValue) }
    }
    
    var tapCount: Int {
        get { getParam("tapCount", default: LRConstants.combFilterTaps) }
        set { setParam("tapCount", value: newValue) }
    }
    
    // MARK: - State
    
    private var combDelayLine: [Float]
    private var combWritePos: Int = 0
    private let combDelayLength: Int
    private var sourceNode: AVAudioSourceNode?
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        let base = (params["baseDelay"] as? Int) ?? LRConstants.combBaseDelay
        self.combDelayLength = base * LRConstants.combFilterTaps * 2
        self.combDelayLine = [Float](repeating: 0, count: combDelayLength)
        
        super.init(
            id: id,
            nodeType: "comb_filter",
            category: .effect,
            displayName: "COMB FILTER"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        // Initialize delay line with defaults - will be configured by setParam
        let base = LRConstants.combBaseDelay
        self.combDelayLength = base * LRConstants.combFilterTaps * 2
        self.combDelayLine = [Float](repeating: 0, count: combDelayLength)
        try super.init(from: decoder)
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "feedback_cv", label: "FEEDBACK CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }
            
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            self.processComb(data, frameCount: Int(frameCount))
            
            return noErr
        }
    }
    
    // MARK: - Processing
    
    private func processComb(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard feedback > 0.001 else { return }
        
        let delay = baseDelay
        let taps = tapCount
        
        for i in 0..<frameCount {
            var combSum: Float = 0
            
            for tap in 0..<taps {
                let delayAmount = delay * (tap + 1)
                if delayAmount < combDelayLength {
                    let readPos = (combWritePos - delayAmount + combDelayLength) % combDelayLength
                    combSum += combDelayLine[readPos]
                }
            }
            combSum /= Float(taps)
            
            let mixed = data[i] + combSum * feedback
            let safe = mixed.isNaN || mixed.isInfinite ? 0 : mixed
            
            combDelayLine[combWritePos] = safe
            combWritePos = (combWritePos + 1) % combDelayLength
            
            data[i] = safe
        }
    }
}

// MARK: - Tunable Resonator Node

/// Pitched comb filter tuned to specific frequency.
/// Transforms metallic sheen into musical resonance.
final class TunableResonatorNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var pitch: Float {
        get { getParam("pitch", default: 440.0) }
        set { setParam("pitch", value: newValue) }
    }
    
    var decay: Float {
        get { getParam("decay", default: 0.85) }
        set { setParam("decay", value: newValue) }
    }
    
    var wetDryMix: Float {
        get { getParam("wetDryMix", default: 0.5) }
        set { setParam("wetDryMix", value: newValue) }
    }
    
    // MARK: - State
    
    private var resonatorDelayLine: [Float]
    private var resonatorWritePos: Int = 0
    private let resonatorMaxDelay: Int
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:], sampleRate: Double = LRConstants.sampleRate) {
        self.sampleRate = sampleRate
        self.resonatorMaxDelay = Int(sampleRate / Double(LRConstants.resonatorPitchRange.lowerBound))
        self.resonatorDelayLine = [Float](repeating: 0, count: resonatorMaxDelay)
        
        super.init(
            id: id,
            nodeType: "tunable_resonator",
            category: .effect,
            displayName: "RESONATOR"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        self.sampleRate = LRConstants.sampleRate
        self.resonatorMaxDelay = Int(LRConstants.sampleRate / Double(LRConstants.resonatorPitchRange.lowerBound))
        self.resonatorDelayLine = [Float](repeating: 0, count: resonatorMaxDelay)
        try super.init(from: decoder)
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "pitch_cv", label: "PITCH CV", signalType: .control, direction: .input),
            NodePort(id: "decay_cv", label: "DECAY CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }
            
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            self.processResonator(data, frameCount: Int(frameCount))
            
            return noErr
        }
    }
    
    // MARK: - Processing
    
    private func processResonator(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard pitch >= LRConstants.resonatorPitchRange.lowerBound else { return }
        
        let delaySamples = Int(sampleRate / Double(pitch))
        guard delaySamples > 0, delaySamples < resonatorMaxDelay else { return }
        
        let resonatorFeedback = min(decay, 0.99)
        let wet = wetDryMix
        let dry = 1.0 - wet
        
        for i in 0..<frameCount {
            let readPos = (resonatorWritePos - delaySamples + resonatorMaxDelay) % resonatorMaxDelay
            let delayed = resonatorDelayLine[readPos]
            
            let mixed = data[i] + delayed * resonatorFeedback
            let safeMixed = mixed.isNaN || mixed.isInfinite ? 0 : mixed
            
            resonatorDelayLine[resonatorWritePos] = safeMixed
            resonatorWritePos = (resonatorWritePos + 1) % resonatorMaxDelay
            
            data[i] = dry * data[i] + wet * safeMixed
        }
    }
}

// MARK: - Bit Crusher Node

/// Sample quantization (bit depth reduction).
/// Creates "Granular Dust" artifact from high-quantization textures.
final class BitCrusherNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var depth: Float {
        get { getParam("depth", default: 0.0) }
        set { setParam("depth", value: newValue) }
    }
    
    // MARK: - State
    
    private var sourceNode: AVAudioSourceNode?
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "bit_crusher",
            category: .effect,
            displayName: "BIT CRUSHER"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "depth_cv", label: "DEPTH CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }
            
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            self.processBitCrush(data, frameCount: Int(frameCount))
            
            return noErr
        }
    }
    
    // MARK: - Processing
    
    private func processBitCrush(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard depth > 0.001 else { return }
        
        let maxBits: Float = 16.0
        let minBits: Float = 2.0
        let shaped = powf(depth, 1.5)
        let bits = maxBits - shaped * (maxBits - minBits)
        let levels = powf(2.0, bits)
        
        for i in 0..<frameCount {
            data[i] = roundf(data[i] * levels) / levels
        }
    }
}

// MARK: - Waveshaper Node

/// Nonlinear distortion with multiple transfer functions.
/// Analog circuit emulation: clean, tube, transistor, diode.
final class WaveshaperNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var gain: Float {
        get { getParam("gain", default: 1.0) }
        set { setParam("gain", value: newValue) }
    }
    
    var mode: SaturationMode {
        get { getParam("mode", default: .clean) }
        set { setParam("mode", value: newValue) }
    }
    
    var morphPosition: Float {
        get { getParam("morphPosition", default: 0.0) }
        set { setParam("morphPosition", value: newValue) }
    }
    
    // MARK: - State
    
    private var sourceNode: AVAudioSourceNode?
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "waveshaper",
            category: .effect,
            displayName: "WAVESHAPER"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "gain_cv", label: "GAIN CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }
            
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            self.processWaveshaper(data, frameCount: Int(frameCount))
            
            return noErr
        }
    }
    
    // MARK: - Processing
    
    private func processWaveshaper(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        let g = gain
        let modes = SaturationMode.allCases
        let currentIdx = modes.firstIndex(of: mode) ?? 0
        let nextIdx = (currentIdx + 1) % modes.count
        let nextMode = modes[nextIdx]
        
        let morph = morphPosition
        
        for i in 0..<frameCount {
            let x = data[i]
            let a = shapeSample(x, gain: g, mode: mode)
            let b = shapeSample(x, gain: g, mode: nextMode)
            data[i] = (1.0 - morph) * a + morph * b
        }
    }
    
    @inline(__always)
    private func shapeSample(_ x: Float, gain: Float, mode: SaturationMode) -> Float {
        switch mode {
        case .clean:
            return tanhf(x * gain)
        case .tube:
            let g = x * gain
            let soft = g / (1.0 + fabsf(g))
            return soft + 0.1 * soft * fabsf(soft)
        case .transistor:
            return tanhf(x * gain * 2.5) * 0.8
        case .diode:
            let g = x * gain
            return g > 0.0 ? min(g, 0.6) : max(g * 1.2, -1.0)
        }
    }
}

// MARK: - Delay Line Node

/// Simple feedback delay with time and feedback controls.
final class DelayLineNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var delayTime: Float {
        get { getParam("delayTime", default: 0.25) }
        set { setParam("delayTime", value: newValue) }
    }
    
    var feedback: Float {
        get { getParam("feedback", default: 0.5) }
        set { setParam("feedback", value: newValue) }
    }
    
    var wetDryMix: Float {
        get { getParam("wetDryMix", default: 0.3) }
        set { setParam("wetDryMix", value: newValue) }
    }
    
    // MARK: - State
    
    private var delayBuffer: [Float]
    private var writePos: Int = 0
    private let maxDelayLength: Int
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:], sampleRate: Double = LRConstants.sampleRate) {
        self.sampleRate = sampleRate
        self.maxDelayLength = Int(sampleRate * 2.0)
        self.delayBuffer = [Float](repeating: 0, count: maxDelayLength)
        
        super.init(
            id: id,
            nodeType: "delay_line",
            category: .effect,
            displayName: "DELAY"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        self.sampleRate = LRConstants.sampleRate
        self.maxDelayLength = Int(LRConstants.sampleRate * 2.0)
        self.delayBuffer = [Float](repeating: 0, count: maxDelayLength)
        try super.init(from: decoder)
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "time_cv", label: "TIME CV", signalType: .control, direction: .input),
            NodePort(id: "feedback_cv", label: "FB CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }
            
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            
            self.processDelay(data, frameCount: Int(frameCount))
            
            return noErr
        }
    }
    
    // MARK: - Processing
    
    private func processDelay(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        let delaySamples = Int(delayTime * Float(sampleRate))
        guard delaySamples > 0, delaySamples < maxDelayLength else { return }
        
        let fb = min(feedback, 0.99)
        let wet = wetDryMix
        let dry = 1.0 - wet
        
        for i in 0..<frameCount {
            let readPos = (writePos - delaySamples + maxDelayLength) % maxDelayLength
            let delayed = delayBuffer[readPos]
            
            let mixed = data[i] + delayed * fb
            let safe = mixed.isNaN || mixed.isInfinite ? 0 : mixed
            
            delayBuffer[writePos] = safe
            writePos = (writePos + 1) % maxDelayLength
            
            data[i] = dry * data[i] + wet * delayed
        }
    }
}
