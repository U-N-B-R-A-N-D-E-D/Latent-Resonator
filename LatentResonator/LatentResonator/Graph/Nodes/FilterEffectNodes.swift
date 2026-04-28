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

    /// Independent comb delay lines per channel.
    private var combDelayLineL: [Float]
    private var combDelayLineR: [Float]
    private var combWritePosL: Int = 0
    private var combWritePosR: Int = 0
    private let combDelayLength: Int

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        let base = (params["baseDelay"] as? Int) ?? LRConstants.combBaseDelay
        self.combDelayLength = base * LRConstants.combFilterTaps * 2
        self.combDelayLineL = [Float](repeating: 0, count: combDelayLength)
        self.combDelayLineR = [Float](repeating: 0, count: combDelayLength)

        super.init(
            id: id,
            nodeType: "comb_filter",
            category: .effect,
            displayName: "COMB FILTER"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        // Initialize delay lines with defaults; they'll be configured by setParam.
        let base = LRConstants.combBaseDelay
        self.combDelayLength = base * LRConstants.combFilterTaps * 2
        self.combDelayLineL = [Float](repeating: 0, count: combDelayLength)
        self.combDelayLineR = [Float](repeating: 0, count: combDelayLength)
        try super.init(from: decoder)
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "feedback_cv", label: "FEEDBACK CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Processing

    @inline(__always)
    fileprivate func processChannel(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        delay: Int,
        taps: Int,
        feedback fb: Float,
        buffer: inout [Float],
        writePos: inout Int
    ) {
        let invTaps = 1.0 / Float(max(taps, 1))
        for i in 0..<frameCount {
            var combSum: Float = 0
            for tap in 0..<taps {
                let delayAmount = delay * (tap + 1)
                if delayAmount < combDelayLength {
                    let readPos = (writePos - delayAmount + combDelayLength) % combDelayLength
                    combSum += buffer[readPos]
                }
            }
            combSum *= invTaps

            let mixed = input[i] + combSum * fb
            let safe = mixed.isNaN || mixed.isInfinite ? 0 : mixed

            buffer[writePos] = safe
            writePos = (writePos + 1) % combDelayLength

            output[i] = safe
        }
    }
}

// MARK: - CombFilterNode + DSPNode

extension CombFilterNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        let fb = feedback

        // Bypass when feedback is essentially zero — pass input through as-is
        // rather than running the loop and emitting unchanged samples.
        if fb <= 0.001 {
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        let delay = baseDelay
        let taps = tapCount

        processChannel(
            input: inBuf.left, output: output.left, frameCount: frameCount,
            delay: delay, taps: taps, feedback: fb,
            buffer: &combDelayLineL, writePos: &combWritePosL
        )
        processChannel(
            input: inBuf.right, output: output.right, frameCount: frameCount,
            delay: delay, taps: taps, feedback: fb,
            buffer: &combDelayLineR, writePos: &combWritePosR
        )
    }

    func reset() {
        for i in 0..<combDelayLineL.count { combDelayLineL[i] = 0 }
        for i in 0..<combDelayLineR.count { combDelayLineR[i] = 0 }
        combWritePosL = 0
        combWritePosR = 0
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

    private var resonatorDelayLineL: [Float]
    private var resonatorDelayLineR: [Float]
    private var resonatorWritePosL: Int = 0
    private var resonatorWritePosR: Int = 0
    private let resonatorMaxDelay: Int

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Sized for the lowest pitch in `LRConstants.resonatorPitchRange`
        // (~20 Hz) at 48 kHz → ~2400 samples — once at init, never grown.
        self.resonatorMaxDelay = Int(LRConstants.sampleRate / Double(LRConstants.resonatorPitchRange.lowerBound))
        self.resonatorDelayLineL = [Float](repeating: 0, count: resonatorMaxDelay)
        self.resonatorDelayLineR = [Float](repeating: 0, count: resonatorMaxDelay)

        super.init(
            id: id,
            nodeType: "tunable_resonator",
            category: .effect,
            displayName: "RESONATOR"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        self.resonatorMaxDelay = Int(LRConstants.sampleRate / Double(LRConstants.resonatorPitchRange.lowerBound))
        self.resonatorDelayLineL = [Float](repeating: 0, count: resonatorMaxDelay)
        self.resonatorDelayLineR = [Float](repeating: 0, count: resonatorMaxDelay)
        try super.init(from: decoder)
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

    // MARK: - Processing

    @inline(__always)
    fileprivate func processChannel(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        delaySamples: Int,
        feedback fb: Float,
        wet: Float,
        dry: Float,
        buffer: inout [Float],
        writePos: inout Int
    ) {
        for i in 0..<frameCount {
            let readPos = (writePos - delaySamples + resonatorMaxDelay) % resonatorMaxDelay
            let delayed = buffer[readPos]

            let mixed = input[i] + delayed * fb
            let safeMixed = mixed.isNaN || mixed.isInfinite ? 0 : mixed

            buffer[writePos] = safeMixed
            writePos = (writePos + 1) % resonatorMaxDelay

            output[i] = dry * input[i] + wet * safeMixed
        }
    }
}

// MARK: - TunableResonatorNode + DSPNode

extension TunableResonatorNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        let p = pitch
        guard p >= LRConstants.resonatorPitchRange.lowerBound else {
            // Pitch out of range → passthrough so the user still hears
            // their input while sweeping the knob across the dead zone.
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        let delaySamples = Int(sampleRate / Double(p))
        guard delaySamples > 0, delaySamples < resonatorMaxDelay else {
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        let fb = min(decay, 0.99)
        let wet = wetDryMix
        let dry = 1.0 - wet

        processChannel(
            input: inBuf.left, output: output.left, frameCount: frameCount,
            delaySamples: delaySamples, feedback: fb, wet: wet, dry: dry,
            buffer: &resonatorDelayLineL, writePos: &resonatorWritePosL
        )
        processChannel(
            input: inBuf.right, output: output.right, frameCount: frameCount,
            delaySamples: delaySamples, feedback: fb, wet: wet, dry: dry,
            buffer: &resonatorDelayLineR, writePos: &resonatorWritePosR
        )
    }

    func reset() {
        for i in 0..<resonatorDelayLineL.count { resonatorDelayLineL[i] = 0 }
        for i in 0..<resonatorDelayLineR.count { resonatorDelayLineR[i] = 0 }
        resonatorWritePosL = 0
        resonatorWritePosR = 0
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
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "depth_cv", label: "DEPTH CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
}

// MARK: - BitCrusherNode + DSPNode

extension BitCrusherNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        let d = depth

        // Bypass when depth is essentially zero — passthrough avoids
        // round-off noise floor introduced by quantizing at 16 bits.
        if d <= 0.001 {
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        let maxBits: Float = 16.0
        let minBits: Float = 2.0
        let shaped = powf(d, 1.5)
        let bits = maxBits - shaped * (maxBits - minBits)
        let levels = powf(2.0, bits)
        let invLevels = 1.0 / levels

        for i in 0..<frameCount {
            output.left[i]  = roundf(inBuf.left[i]  * levels) * invLevels
            output.right[i] = roundf(inBuf.right[i] * levels) * invLevels
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
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "gain_cv", label: "GAIN CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Saturation primitives

    /// Per-sample analog-circuit emulation. Stateless; selected by `SaturationMode`.
    @inline(__always)
    fileprivate func shapeSample(_ x: Float, gain: Float, mode: SaturationMode) -> Float {
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

// MARK: - WaveshaperNode + DSPNode

extension WaveshaperNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        let g = gain
        let m = mode
        let morph = morphPosition

        if morph < 0.001 {
            // Single-mode fast path — avoids the second `shapeSample` call.
            for i in 0..<frameCount {
                output.left[i]  = shapeSample(inBuf.left[i],  gain: g, mode: m)
                output.right[i] = shapeSample(inBuf.right[i], gain: g, mode: m)
            }
            return
        }

        // Two-mode crossfade morph (CLEAN → TUBE → TRANSISTOR → DIODE).
        let modes = SaturationMode.allCases
        let currentIdx = modes.firstIndex(of: m) ?? 0
        let nextMode = modes[(currentIdx + 1) % modes.count]
        let oneMinus = 1.0 - morph

        for i in 0..<frameCount {
            let aL = shapeSample(inBuf.left[i],  gain: g, mode: m)
            let bL = shapeSample(inBuf.left[i],  gain: g, mode: nextMode)
            output.left[i] = oneMinus * aL + morph * bL

            let aR = shapeSample(inBuf.right[i], gain: g, mode: m)
            let bR = shapeSample(inBuf.right[i], gain: g, mode: nextMode)
            output.right[i] = oneMinus * aR + morph * bR
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

    /// Independent delay buffers per channel — true stereo. Sharing one
    /// buffer across L/R would collapse the stereo image of the input
    /// signal into mono.
    private var delayBufferL: [Float]
    private var delayBufferR: [Float]
    private var writePosL: Int = 0
    private var writePosR: Int = 0
    private let maxDelayLength: Int

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Two-second maximum delay at the canonical sample rate. Sized
        // once so the audio thread never reallocates.
        self.maxDelayLength = Int(LRConstants.sampleRate * 2.0)
        self.delayBufferL = [Float](repeating: 0, count: maxDelayLength)
        self.delayBufferR = [Float](repeating: 0, count: maxDelayLength)

        super.init(
            id: id,
            nodeType: "delay_line",
            category: .effect,
            displayName: "DELAY"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        self.maxDelayLength = Int(LRConstants.sampleRate * 2.0)
        self.delayBufferL = [Float](repeating: 0, count: maxDelayLength)
        self.delayBufferR = [Float](repeating: 0, count: maxDelayLength)
        try super.init(from: decoder)
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

    // MARK: - Processing

    /// Single-channel feedback delay loop. The delay buffer + write head
    /// are passed `inout` so `render(...)` can hold separate state per
    /// channel without duplicating the inner loop.
    @inline(__always)
    fileprivate func processChannel(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        delaySamples: Int,
        feedback fb: Float,
        wet: Float,
        dry: Float,
        buffer: inout [Float],
        writePos: inout Int
    ) {
        for i in 0..<frameCount {
            let readPos = (writePos - delaySamples + maxDelayLength) % maxDelayLength
            let delayed = buffer[readPos]

            let mixed = input[i] + delayed * fb
            let safe = mixed.isNaN || mixed.isInfinite ? 0 : mixed

            buffer[writePos] = safe
            writePos = (writePos + 1) % maxDelayLength

            output[i] = dry * input[i] + wet * delayed
        }
    }
}

// MARK: - DelayLineNode + DSPNode

extension DelayLineNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        guard let inBuf = inputs.first else {
            // No input — emit silence (and stop chasing the tail of an
            // arbitrary previous buffer).
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        let delaySamples = Int(delayTime * Float(sampleRate))
        guard delaySamples > 0, delaySamples < maxDelayLength else {
            // Delay time out of range → passthrough.
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        let fb = min(feedback, 0.99)
        let wet = wetDryMix
        let dry = 1.0 - wet

        processChannel(
            input: inBuf.left, output: output.left, frameCount: frameCount,
            delaySamples: delaySamples, feedback: fb, wet: wet, dry: dry,
            buffer: &delayBufferL, writePos: &writePosL
        )
        processChannel(
            input: inBuf.right, output: output.right, frameCount: frameCount,
            delaySamples: delaySamples, feedback: fb, wet: wet, dry: dry,
            buffer: &delayBufferR, writePos: &writePosR
        )
    }

    func reset() {
        for i in 0..<delayBufferL.count { delayBufferL[i] = 0 }
        for i in 0..<delayBufferR.count { delayBufferR[i] = 0 }
        writePosL = 0
        writePosR = 0
    }
}
