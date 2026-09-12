import Foundation
import AVFoundation
import Accelerate
import Combine

// MARK: - Spectral Chain Node
//
// The Spectra stage of Latent Resonator (ROAD_TO_V2_UX §3.1). This is the
// single coarse, named stage that encapsulates the full 8-stage spectral
// pipeline (FFT → SemanticEQ → Saturation → Noise → Memory → Granularity
// → Freeze → IFFT). It is the only spectral node registered in `NodeFactory`
// and the only one that conforms to `DSPNode` — the audio engine pulls
// render through it.
//
// The 8 per-stage spectral operations live INSIDE `SpectralPipeline` as
// private stage methods (`stage1_fft`, `stage2_semanticEQ`, ...). They are
// intentionally NOT exposed as independent canvas nodes: fragmenting the
// Spectra stage into 8 sub-nodes would violate the Envion-aligned coarse-
// stage philosophy and produce silence (the individual stage classes of
// the v1.x API did not conform to `DSPNode` and were silently skipped by
// `ExecutionPlan.build`). The v1.x classes were removed when the
// `SpectralChainNode` + `SpectralPipeline` composite became the single
// thing that works.

/// Composite node encapsulating the complete spectral processing pipeline.
///
/// This node combines the 8 spectral processing stages into a single audio node:
/// FFT → SemanticEQ → SpectralSaturation → SpectralNoise → SpectralMemory
/// → SpectralGranularity → SpectralFreeze → IFFT
///
/// Architecture: The spectral pipeline is inherently time→freq→time domain,
/// so it cannot be split into separate audio nodes. Instead, this composite
/// node presents as a single "black box" spectral processor.
///
/// Whitepaper Alignment: Implements the recursive spectral formula S(i+1) = ACE(...)
/// where the spectral chain processes the signal before neural inference.
///
/// References:
///   - Roads: Microsound (2001) — spectral domain time-stretch and frequency-domain filtering
///   - Schaeffer: Traité des objets musicaux (1966) — sound object morphology
///
/// ─── Migration Status (T5 assessment) ───
///
/// SpectralChainNode is already functional on the v2 pull-render path: it
/// conforms to `GraphNodeDSPProvider` / `DSPNode` and `render()` is the live
/// audio callback. The `audioUnit()` override returns nil and is vestigial
/// protocol boilerplate. The `processor: SpectralProcessor` property is also
/// unused — the live path uses `analysisPipeline: SpectralPipeline`.
///
/// Remaining migration work is cleanup, not behavior change:
///   1. Remove `audioUnit()` override (`BaseGraphNode` already returns nil).
///   2. Remove `processor` and the `SpectralProcessor` initialization.
///   3. Decide the fate of `SpectralProcessor.swift` (dead code; only referenced
///      by comments in the bridge/scripts).
///   4. Verify no `AudioInputNode` coupling: there is none; both are ordinary
///      graph nodes that connect via audio edges.
///
/// RT-path risk: low — the live DSP work is inside `SpectralPipeline`; any
/// cleanup must avoid touching that code path. Out of scope for unrelated
/// changes per the v2-node-graph skill.
final class SpectralChainNode: BaseGraphNode {

    // MARK: - Parameters (Exposed from all 8 stages)

    var fftSize: Int {
        get { getParam("fftSize", default: LRConstants.fftSize) }
        set { setParam("fftSize", value: newValue) }
    }

    // Semantic EQ profile (text-based spectral shaping)
    var semanticProfile: String {
        get { getParam("semanticProfile", default: "neutral") }
        set { setParam("semanticProfile", value: newValue) }
    }

    // Spectral saturation
    var saturationAmount: Float {
        get { getParam("saturationAmount", default: 0.0) }
        set { setParam("saturationAmount", value: newValue) }
    }

    // Spectral noise
    var noiseAmount: Float {
        get { getParam("noiseAmount", default: 0.0) }
        set { setParam("noiseAmount", value: newValue) }
    }

    // Spectral memory
    var memoryCoeff: Float {
        get { getParam("memoryCoeff", default: 0.85) }
        set { setParam("memoryCoeff", value: newValue) }
    }

    // Spectral granularity
    var granularity: Float {
        get { getParam("granularity", default: 0.0) }
        set { setParam("granularity", value: newValue) }
    }

    // Spectral freeze
    var freezeActive: Bool {
        get { getParam("freezeActive", default: false) }
        set { setParam("freezeActive", value: newValue) }
    }
    var freezeBlend: Float {
        get { getParam("freezeBlend", default: 0.5) }
        set { setParam("freezeBlend", value: newValue) }
    }

    // MARK: - Internal State

    private let sampleRate: Double
    private var processor: SpectralProcessor
    private var analysisPipeline: SpectralPipeline?
    
    /// Pre-allocated mono scratch for pull-render `DSPNode.render` (no per-block heap).
    private var scratchMono: [Float]
    
    /// Capacity: 2 seconds of audio at 48kHz = 96000 samples.
    /// Capacity reserved for overlap-add state inside `SpectralPipeline`.
    
    // MARK: - v2.0 Spectral Pipeline (8-Stage)
    
    /// Semantic profile cache (4-band EQ: [low, lowMid, highMid, high])
    /// Updated when prompt parameter changes
    private var cachedSemanticProfile: [Float] = [0, 0, 0, 0]

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:], sampleRate: Double = LRConstants.sampleRate) {
        self.sampleRate = sampleRate

        let size = (params["fftSize"] as? Int) ?? LRConstants.fftSize
        let combDelay = (params["combBaseDelay"] as? Int) ?? LRConstants.combBaseDelay

        self.processor = SpectralProcessor(
            sampleRate: sampleRate,
            combBaseDelay: combDelay
        )
        processor.reconfigure(fftSize: size)

        self.scratchMono = [Float](repeating: 0, count: LRConstants.bufferSize * 2)
        
        // Initialize v2.0 spectral pipeline
        self.analysisPipeline = SpectralPipeline(fftSize: size, sampleRate: sampleRate)

        super.init(
            id: id,
            nodeType: "spectral_chain",
            category: .analysis,
            displayName: "SPECTRAL CHAIN"
        )

        for (key, value) in params {
            parameters[key] = value
        }
        
        // Initialize semantic profile cache from prompt
        cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
    }
    
    required init(from decoder: Decoder) throws {
        let sr = LRConstants.sampleRate
        self.sampleRate = sr
        
        let size = LRConstants.fftSize
        let combDelay = LRConstants.combBaseDelay
        
        self.processor = SpectralProcessor(
            sampleRate: sr,
            combBaseDelay: combDelay
        )
        processor.reconfigure(fftSize: size)
        
        self.scratchMono = [Float](repeating: 0, count: LRConstants.bufferSize * 2)
        self.analysisPipeline = SpectralPipeline(fftSize: size, sampleRate: sr)
        
        try super.init(from: decoder)
        
        cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
    }
    
    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "profile_cv", label: "PROFILE", signalType: .control, direction: .input),
            NodePort(id: "freeze_gate", label: "FREEZE", signalType: .gate, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Audio Unit (legacy — pull-render uses `DSPNode` below)

    override func audioUnit() -> AVAudioNode? {
        nil
    }

    // MARK: - Parameter Changes

    override func onParameterChanged(key: String, value: Any) {
        // Most parameters are passed directly to pipeline.process() in audio callback
        // However, prompt changes require rebuilding the semantic profile cache
        if key == "semanticProfile" || key == "prompt" {
            cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
        }
    }

    // MARK: - v2.0 Spectral Pipeline Processing

    /// Run the 8-stage spectral pipeline in-place (no heap traffic on audio thread).
    /// P1.5 — scalar user-facing params are passed in as arguments so the
    /// caller can snapshot them once at the top of `render`; the
    /// `cachedSemanticProfile` array stays read via the pre-existing
    /// stored-property pattern (pre-allocated, mutated only on the main
    /// thread in `onParameterChanged`).
    private func processSpectralPipelineInPlace(
        input: UnsafePointer<Float>,
        frameCount: Int,
        output: UnsafeMutablePointer<Float>,
        saturationAmount: Float,
        noiseAmount: Float,
        memoryCoeff: Float,
        granularity: Float,
        freezeActive: Bool,
        freezeBlend: Float
    ) {
        guard let pipeline = analysisPipeline else {
            for i in 0..<frameCount { output[i] = input[i] }
            return
        }

        if cachedSemanticProfile.isEmpty {
            cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
        }

        cachedSemanticProfile.withUnsafeBufferPointer { profilePtr in
            guard let profileBase = profilePtr.baseAddress else { return }
            pipeline.process(
                input: input,
                frameCount: frameCount,
                output: output,
                semanticProfile: profileBase,
                profileCount: profilePtr.count,
                saturationAmount: saturationAmount,
                noiseAmount: noiseAmount,
                memoryCoefficient: memoryCoeff,
                granularity: granularity,
                freezeActive: freezeActive,
                freezeBlend: freezeBlend
            )
        }
    }

    /// Build 4-band semantic EQ profile from prompt text.
    ///
    /// Whitepaper §2.5: Colored Spectral Noise - semantic descriptors map to frequency bands.
    /// - Low: 0-250 Hz (warm, bass)
    /// - LowMid: 250-1000 Hz (body, richness)
    /// - HighMid: 1000-4000 Hz (presence, clarity)
    /// - High: 4000+ Hz (air, sparkle)
    ///
    /// - Parameter prompt: The semantic prompt text
    /// - Returns: 4-band gain array [low, lowMid, highMid, high] in range [-1, 1]
    private func buildSemanticProfile(from prompt: String) -> [Float] {
        var profile: [Float] = [0, 0, 0, 0]
        let lowered = prompt.lowercased()

        // Parse prompt keywords and build profile
        // Keywords map to specific frequency bands
        let semanticKeywords: [(String, [Float])] = [
            // Warm/bass boost
            ("warm", [0.5, 0.3, 0, -0.2]),
            ("bass", [0.6, 0.2, 0, -0.3]),
            ("deep", [0.4, 0.3, 0, -0.1]),
            ("sub", [0.8, 0, 0, 0]),

            // Rich/body boost
            ("rich", [0.2, 0.5, 0.2, 0]),
            ("full", [0.1, 0.4, 0.2, 0]),
            ("thick", [0.3, 0.4, 0, -0.1]),

            // Presence/clarity boost
            ("clear", [0, 0.2, 0.5, 0.3]),
            ("present", [0, 0.1, 0.6, 0.2]),
            ("forward", [-0.1, 0, 0.5, 0.4]),
            ("vocal", [-0.2, 0, 0.7, 0.3]),

            // Air/sparkle boost
            ("bright", [-0.1, 0, 0.2, 0.6]),
            ("air", [0, 0, 0.1, 0.7]),
            ("sparkle", [0, 0, 0.3, 0.7]),
            ("shimmer", [-0.1, 0, 0.2, 0.8]),

            // Metallic/high boost (§5.4 Metallic Sheen)
            ("metallic", [0, 0, 0.3, 0.8]),
            ("chrome", [-0.1, 0, 0.2, 0.7]),
            ("silver", [0, 0, 0.3, 0.6]),
            ("tin", [0.1, 0.1, 0.3, 0.5]),
            ("aluminum", [0, 0, 0.4, 0.6]),
            ("copper", [0.2, 0, 0.2, 0.5]),

            // Dark/muffled (negative high)
            ("dark", [0.2, 0.1, -0.2, -0.5]),
            ("muffled", [0.1, 0, -0.3, -0.6]),
            ("soft", [0.1, 0.2, -0.1, -0.3]),
            ("dull", [0, 0, -0.2, -0.4]),

            // Sharp/attack boost
            ("sharp", [-0.2, 0, 0.4, 0.5]),
            ("piercing", [-0.3, -0.1, 0.3, 0.7]),
            ("attack", [-0.1, 0, 0.5, 0.4]),
            ("percussive", [0, 0, 0.4, 0.3])
        ]

        for (keyword, gains) in semanticKeywords {
            if lowered.contains(keyword) {
                for i in 0..<4 {
                    profile[i] += gains[i]
                }
            }
        }

        // Normalize to [-1, 1] range
        let maxGain = max(abs(profile.max() ?? 0), abs(profile.min() ?? 0))
        if maxGain > 1.0 {
            for i in 0..<4 {
                profile[i] /= maxGain
            }
        }

        return profile
    }
}

// MARK: - SpectralChainNode + DSPNode (pull-render)

extension SpectralChainNode: GraphNodeDSPProvider, DSPNode {
    var nodeId: UUID { id }
    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // P1.5 — snapshot scalar user-facing params into locals before any
        // DSP work. The `cachedSemanticProfile` array is read via the
        // pre-existing stored-property pattern (pre-allocated, main-thread
        // mutation only) — preserved as-is to avoid breaking RT-safety.
        let sat = saturationAmount
        let noise = noiseAmount
        let mem = memoryCoeff
        let grain = granularity
        let freeze = freezeActive
        let freezeBlnd = freezeBlend

        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        guard frameCount <= scratchMono.count else {
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        for i in 0..<frameCount {
            scratchMono[i] = (inBuf.left[i] + inBuf.right[i]) * 0.5
        }

        scratchMono.withUnsafeBufferPointer { inputPtr in
            guard let inputBase = inputPtr.baseAddress else { return }
            processSpectralPipelineInPlace(
                input: inputBase,
                frameCount: frameCount,
                output: output.left,
                saturationAmount: sat,
                noiseAmount: noise,
                memoryCoeff: mem,
                granularity: grain,
                freezeActive: freeze,
                freezeBlend: freezeBlnd
            )
        }
        for i in 0..<frameCount {
            output.right[i] = output.left[i]
        }
    }

    func reset() {
        analysisPipeline?.reset()
        cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
    }
}

// MARK: - Spectral Feedback Node (Emergence — Round 2 audit, Booth)

/// Spectral attractor: wraps its own private `SpectralPipeline` and closes
/// a feedback loop through a hop-quantized delay buffer, entirely inside
/// Latent Resonator's own DSP — no ACE-Step dependency.
///
/// Round 2 finding (Booth): the only place in the spectral chain with
/// genuine emergence potential is Stage 3 (polar saturation) + Stage 5
/// (leaky memory) of `SpectralPipeline`. Coupling the pipeline's own
/// output back into its input — with a delay (so it's a real feedback
/// path, not instantaneous self-reference) and gain < 1.0 (so it's stable,
/// not explosive) — turns that coupling into a real nonlinear dynamical
/// system with state. This is a spectral-domain sibling of `DelayLineNode`
/// (`FilterEffectNodes.swift`): same delay-buffer-plus-feedback-gain shape,
/// just with a whole `SpectralPipeline.process(...)` call standing in for
/// the single-sample tap, and mono throughout (mirrors `SpectralChainNode`'s
/// downmix/duplicate shape, since the pipeline itself is single-channel).
///
/// There is no graph-level cycle here — `feedbackBuffer` is private state
/// closed over by this one node, exactly like `DelayLineNode`'s own delay
/// line. From the graph's perspective this is an ordinary one-in/one-out
/// node; the recursion is temporal (across render calls), not topological.
final class SpectralFeedbackNode: BaseGraphNode {

    // MARK: - Parameters

    var feedback: Float {
        get { getParam("feedback", default: LRConstants.spectralFeedbackDefault) }
        set { setParam("feedback", value: newValue) }
    }

    var memoryCoeff: Float {
        get { getParam("memoryCoeff", default: LRConstants.spectralFeedbackMemoryDefault) }
        set { setParam("memoryCoeff", value: newValue) }
    }

    var saturationAmount: Float {
        get { getParam("saturationAmount", default: LRConstants.spectralFeedbackSaturationDefault) }
        set { setParam("saturationAmount", value: newValue) }
    }

    var delayHopCount: Int {
        get { getParam("delayHopCount", default: LRConstants.spectralFeedbackHopDelayDefault) }
        set { setParam("delayHopCount", value: newValue) }
    }

    // MARK: - Internal State

    /// Private pipeline instance — this node owns its own spectral chain,
    /// independent of any `SpectralChainNode` elsewhere in the graph.
    private let pipeline: SpectralPipeline
    private let hopSize: Int

    /// Circular buffer holding the pipeline's own past output, read back
    /// `delayHopCount * hopSize` samples later and summed with fresh input
    /// — the closed spectral loop. Sized for the maximum hop count (see
    /// `LRConstants.spectralFeedbackHopDelayRange`) plus one hop of
    /// headroom, so `delaySamples < maxDelayLength` always holds and the
    /// circular-buffer modulo arithmetic never indexes negative.
    private var feedbackBuffer: [Float]
    private var writePos: Int = 0
    private let maxDelayLength: Int

    /// Pre-allocated mono scratch: downmix + feedback-sum in one pass,
    /// then fed straight into `pipeline.process(...)`. No per-block heap
    /// traffic — sized once at init like `SpectralChainNode.scratchMono`.
    private var mixedInput: [Float]

    /// Flat (no-op) 4-band profile — this node has no semantic/prompt
    /// coloration of its own, unlike `SpectralChainNode`. Passing all
    /// zeros makes `stage2_semanticEQ`'s per-band gain `1.0 + 0 == 1.0`,
    /// i.e. transparent.
    private let neutralProfile: [Float] = [0, 0, 0, 0]

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:], sampleRate: Double = LRConstants.sampleRate) {
        let fftSize = LRConstants.fftSize
        let hop = fftSize / 2
        self.hopSize = hop
        self.maxDelayLength = (LRConstants.spectralFeedbackHopDelayRange.upperBound + 1) * hop

        self.pipeline = SpectralPipeline(fftSize: fftSize, sampleRate: sampleRate)
        self.feedbackBuffer = [Float](repeating: 0, count: maxDelayLength)
        self.mixedInput = [Float](repeating: 0, count: LRConstants.bufferSize * 2)

        super.init(
            id: id,
            nodeType: "spectral_feedback",
            category: .effect,
            displayName: "SPECTRAL FEEDBACK"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        let fftSize = LRConstants.fftSize
        let hop = fftSize / 2
        self.hopSize = hop
        self.maxDelayLength = (LRConstants.spectralFeedbackHopDelayRange.upperBound + 1) * hop

        self.pipeline = SpectralPipeline(fftSize: fftSize, sampleRate: LRConstants.sampleRate)
        self.feedbackBuffer = [Float](repeating: 0, count: maxDelayLength)
        self.mixedInput = [Float](repeating: 0, count: LRConstants.bufferSize * 2)

        try super.init(from: decoder)
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
}

// MARK: - SpectralFeedbackNode + DSPNode

extension SpectralFeedbackNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        guard frameCount <= mixedInput.count else {
            for i in 0..<frameCount {
                output.left[i] = inBuf.left[i]
                output.right[i] = inBuf.right[i]
            }
            return
        }

        // P1.5 — snapshot user-facing params once before any DSP work.
        // `fb` mirrors DelayLineNode's `min(feedback, LRConstants.feedbackCap)`
        // defense-in-depth clamp (the 0...0.95 range above is the exposed
        // control's range; this is the render-path safety net against an
        // unclamped CV push, same class of bug as Fix 1/LadderFilterNode).
        let fb = min(feedback, LRConstants.feedbackCap)
        let mem = memoryCoeff
        let sat = saturationAmount
        let hops = min(max(delayHopCount, LRConstants.spectralFeedbackHopDelayRange.lowerBound),
                        LRConstants.spectralFeedbackHopDelayRange.upperBound)
        let delaySamples = hops * hopSize
        let wp = writePos

        // Close the loop: downmix to mono, read the pipeline's own past
        // output from `delaySamples` ago, scale by feedback, sum with the
        // fresh input. Per-sample equivalent of DelayLineNode's
        // `input[i] + delayed*fb`, just with a whole SpectralPipeline
        // standing between write and read instead of a single tap.
        // NaN/Inf guard mirrors CombFilterNode's feedback-tap guard
        // (~line 303 in FilterEffectNodes.swift) — this is the value that
        // both drives the pipeline AND (after processing) re-enters
        // `feedbackBuffer`, so a guard here protects the loop's state,
        // not just one sample.
        for i in 0..<frameCount {
            let mono = (inBuf.left[i] + inBuf.right[i]) * 0.5
            let readPos = (wp + i - delaySamples + maxDelayLength) % maxDelayLength
            let delayed = feedbackBuffer[readPos]
            let mixed = mono + delayed * fb
            mixedInput[i] = mixed.isNaN || mixed.isInfinite ? 0 : mixed
        }

        mixedInput.withUnsafeBufferPointer { inPtr in
            neutralProfile.withUnsafeBufferPointer { profPtr in
                guard let inBase = inPtr.baseAddress, let profBase = profPtr.baseAddress else { return }
                pipeline.process(
                    input: inBase,
                    frameCount: frameCount,
                    output: output.left,
                    semanticProfile: profBase,
                    profileCount: profPtr.count,
                    saturationAmount: sat,
                    noiseAmount: 0,
                    memoryCoefficient: mem,
                    granularity: 0,
                    freezeActive: false,
                    freezeBlend: 0
                )
            }
        }

        // Write this block's (guarded) output back into the delay buffer —
        // the state that closes the loop for a future block — and
        // duplicate mono → stereo, mirroring SpectralChainNode.
        for i in 0..<frameCount {
            let sample = output.left[i]
            let safe = sample.isNaN || sample.isInfinite ? 0 : sample
            output.left[i] = safe
            output.right[i] = safe
            feedbackBuffer[(wp + i) % maxDelayLength] = safe
        }
        writePos = (wp + frameCount) % maxDelayLength
    }

    func reset() {
        for i in 0..<feedbackBuffer.count { feedbackBuffer[i] = 0 }
        writePos = 0
        pipeline.reset()
    }
}
