import Foundation
import AVFoundation
import Combine

// MARK: - ACE-Step Inference Node

/// Async neural inference node wrapping ACEStepBridge.
/// Takes audio input, performs diffusion model inference, outputs processed audio.
final class ACEStepInferenceNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var prompt: String {
        get { getParam("prompt", default: "") }
        set { setParam("prompt", value: newValue) }
    }
    
    var guidanceScale: Float {
        get { getParam("guidanceScale", default: LRConstants.cfgScaleDefault) }
        set { setParam("guidanceScale", value: newValue) }
    }
    
    var numSteps: Int {
        get { getParam("numSteps", default: LRConstants.aceStepsDefault) }
        set { setParam("numSteps", value: newValue) }
    }
    
    var inputStrength: Float {
        get { getParam("inputStrength", default: LRConstants.inputStrengthDefault) }
        set { setParam("inputStrength", value: newValue) }
    }
    
    var entropy: Float {
        get { getParam("entropy", default: 0.25) }
        set { setParam("entropy", value: newValue) }
    }
    
    var granularity: Float {
        get { getParam("granularity", default: 0.45) }
        set { setParam("granularity", value: newValue) }
    }
    
    var taskType: String {
        get { getParam("taskType", default: LRConstants.aceTaskTypeDefault) }
        set { setParam("taskType", value: newValue) }
    }
    
    var thinking: Bool {
        get { getParam("thinking", default: LRConstants.aceThinkingDefault) }
        set { setParam("thinking", value: newValue) }
    }
    
    // MARK: - State
    
    private weak var bridge: ACEStepBridge?
    private var inputBuffer: [Float] = []
    private var outputBuffer: [Float] = []
    private var isProcessing: Bool = false
    private var lastInferenceTime: Date?
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:], bridge: ACEStepBridge? = nil) {
        self.bridge = bridge
        
        super.init(
            id: id,
            nodeType: "ace_step_inference",
            category: .neural,
            displayName: "ACE INFERENCE"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // bridge will be connected at runtime
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "prompt_in", label: "PROMPT", signalType: .control, direction: .input),
            NodePort(id: "cfg_cv", label: "CFG CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output),
            NodePort(id: "status", label: "STATUS", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Telemetry
    
    override var telemetry: NodeTelemetry {
        NodeTelemetry(
            rmsLevel: 0.0,
            spectralCentroid: 0.0,
            spectralFlatness: 0.0,
            level: isProcessing ? 1.0 : 0.0,
            isActive: isProcessing,
            cpuUsage: 0.5
        )
    }
    
    // MARK: - Processing
    
    /// Accumulate input samples for inference.
    /// When buffer reaches target size, trigger async inference.
    func accumulate(_ samples: [Float]) {
        inputBuffer.append(contentsOf: samples)
        
        // Trigger inference when we have enough samples (~1 sec of audio)
        let targetSize = Int(LRConstants.sampleRate)
        if inputBuffer.count >= targetSize && !isProcessing {
            triggerInference()
        }
    }
    
    /// Asynchronously run inference via ACEStepBridge.
    private func triggerInference() {
        guard let bridge = bridge else { return }
        guard bridge.status == .modelLoaded else { return }
        
        isProcessing = true
        let chunk = Array(inputBuffer.prefix(Int(LRConstants.sampleRate)))
        inputBuffer.removeFirst(chunk.count)
        
        Task {
            do {
                let result = try await bridge.infer(
                    samples: chunk,
                    prompt: prompt,
                    guidanceScale: guidanceScale,
                    numSteps: numSteps,
                    inputStrength: inputStrength,
                    entropy: entropy,
                    granularity: granularity,
                    taskType: taskType,
                    thinking: thinking
                )
                
                await MainActor.run {
                    self.outputBuffer = result
                    self.isProcessing = false
                    self.lastInferenceTime = Date()
                }
            } catch {
                print("ACEStepInferenceNode: inference failed - \(error)")
                await MainActor.run {
                    self.isProcessing = false
                }
            }
        }
    }
    
    /// Read processed samples from the output buffer.
    func read(_ count: Int) -> [Float] {
        guard !outputBuffer.isEmpty else {
            return Array(repeating: 0, count: count)
        }
        
        let available = min(count, outputBuffer.count)
        let chunk = Array(outputBuffer.prefix(available))
        outputBuffer.removeFirst(available)
        
        if chunk.count < count {
            return chunk + Array(repeating: 0, count: count - chunk.count)
        }
        
        return chunk
    }
}

// MARK: - Prompt Engine Node

/// 3-Phase evolutionary prompt engine implementing whitepaper §4.2.2.
///
/// The prompt evolves across three phases driven by spectral flatness:
/// - Phase 1 (Harmonic): Low flatness - tonal, structured, warm
/// - Phase 2 (Transitional): Medium flatness - evolving, drifting, textured
/// - Phase 3 (Chaotic): High flatness - granular, entropic, saturated
///
/// Each phase has its own prompt string. The effective prompt is determined
/// by interpolating between phases based on current spectral flatness.
///
/// Whitepaper alignment: "Recursive Drift Trajectory" (§4.2.2)
final class PromptEngineNode: BaseGraphNode {

    // MARK: - 3-Phase Evolution Parameters

    /// Phase 1: Low spectral flatness (0.0 - threshold1) = Harmonic/Tonal
    var phase1Prompt: String {
        get { getParam("phase1Prompt", default: "ferrofluid, subharmonic, warm resonance") }
        set { setParam("phase1Prompt", value: newValue) }
    }

    /// Phase 2: Medium spectral flatness (threshold1 - threshold2) = Transitional
    var phase2Prompt: String {
        get { getParam("phase2Prompt", default: "spectral drift, evolving texture") }
        set { setParam("phase2Prompt", value: newValue) }
    }

    /// Phase 3: High spectral flatness (threshold2 - 1.0) = Chaotic/Noise-like
    var phase3Prompt: String {
        get { getParam("phase3Prompt", default: "granular chaos, noise as structure") }
        set { setParam("phase3Prompt", value: newValue) }
    }

    /// Threshold for phase 1→2 transition (flatness value 0-1)
    /// Default: 0.35 per whitepaper §4.2.2
    var phase1to2Threshold: Float {
        get { getParam("phase1to2Threshold", default: LRConstants.spectralPhase2Threshold) }
        set { setParam("phase1to2Threshold", value: newValue) }
    }

    /// Threshold for phase 2→3 transition
    /// Default: 0.65 per whitepaper §4.2.2
    var phase2to3Threshold: Float {
        get { getParam("phase2to3Threshold", default: LRConstants.spectralPhase3Threshold) }
        set { setParam("phase2to3Threshold", value: newValue) }
    }

    /// Smoothing factor for phase transitions (0-1). Higher = smoother interpolation.
    var transitionSmoothing: Float {
        get { getParam("transitionSmoothing", default: 0.5) }
        set { setParam("transitionSmoothing", value: newValue) }
    }

    // MARK: - Legacy Single Prompt (Backward Compatibility)

    /// Single prompt text (legacy). When set, applies to phase1 and clears others.
    var text: String {
        get { return phase1Prompt }
        set {
            phase1Prompt = newValue
            phase2Prompt = ""
            phase3Prompt = ""
        }
    }

    // MARK: - State

    /// Current spectral flatness (updated by analysis nodes)
    @Published var currentFlatness: Float = 0.0

    /// Current active phase (1, 2, or 3) for UI feedback
    var currentPhase: Int {
        if currentFlatness < phase1to2Threshold { return 1 }
        if currentFlatness < phase2to3Threshold { return 2 }
        return 3
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        phase1: String = "ferrofluid, subharmonic, warm resonance",
        phase2: String = "spectral drift, evolving texture",
        phase3: String = "granular chaos, noise as structure",
        threshold12: Float = 0.35,
        threshold23: Float = 0.65,
        smoothing: Float = 0.5
    ) {
        super.init(
            id: id,
            nodeType: "prompt_engine",
            category: .neural,
            displayName: "PROMPT ENGINE"
        )

        self.phase1Prompt = phase1
        self.phase2Prompt = phase2
        self.phase3Prompt = phase3
        self.phase1to2Threshold = threshold12
        self.phase2to3Threshold = threshold23
        self.transitionSmoothing = smoothing
    }

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "prompt_engine",
            category: .neural,
            displayName: "PROMPT ENGINE"
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
            NodePort(id: "flatness_in", label: "FLAT", signalType: .control, direction: .input),
            NodePort(id: "text_out", label: "PROMPT", signalType: .control, direction: .output),
            NodePort(id: "phase_cv", label: "PHASE", signalType: .control, direction: .output)
        ]
    }

    // MARK: - Telemetry

    override var telemetry: NodeTelemetry {
        NodeTelemetry(
            rmsLevel: 0.0,
            spectralCentroid: Float(currentPhase) * 0.33, // Visual indicator of phase
            spectralFlatness: currentFlatness,
            level: 0.5,
            isActive: !effectivePrompt.isEmpty,
            cpuUsage: 0.0
        )
    }

    // MARK: - 3-Phase Evolution Logic

    /// Get the effective prompt based on current spectral flatness.
    /// Implements smooth interpolation between phases per whitepaper §4.2.2.
    var effectivePrompt: String {
        let flatness = currentFlatness
        let t1 = phase1to2Threshold
        let t2 = phase2to3Threshold

        // Phase 1: Pure harmonic
        if flatness < t1 {
            return phase1Prompt
        }

        // Phase 1→2: Interpolate
        if flatness < t2 {
            let t = (flatness - t1) / (t2 - t1)
            let smoothed = smoothstep(t, edge0: 0, edge1: 1)
            return interpolatePrompts(phase1Prompt, phase2Prompt, t: smoothed)
        }

        // Phase 2→3: Interpolate
        let t = (flatness - t2) / (1.0 - t2)
        let smoothed = smoothstep(t, edge0: 0, edge1: 1)
        return interpolatePrompts(phase2Prompt, phase3Prompt, t: smoothed)
    }

    /// Get the effective prompt for a given flatness value (external input).
    func effectivePrompt(forFlatness flatness: Float) -> String {
        self.currentFlatness = flatness
        objectWillChange.send()
        return effectivePrompt
    }

    /// Update flatness from control input and recalculate effective prompt.
    func updateFlatness(_ value: Float) -> String {
        currentFlatness = value
        objectWillChange.send()
        return effectivePrompt
    }

    // MARK: - Text Output

    /// Get the text output for text-type ports (downstream ACE inference).
    func evaluateText() -> String {
        return effectivePrompt
    }

    /// Get current phase as control value (0.0, 0.5, or 1.0).
    func evaluateControl(portId: String, at time: TimeInterval) -> Float {
        switch portId {
        case "phase_cv":
            switch currentPhase {
            case 1: return 0.0
            case 2: return 0.5
            case 3: return 1.0
            default: return 0.0
            }
        default:
            return 0.0
        }
    }

    // MARK: - Private Helpers

    /// Smooth step function for gentle transitions.
    private func smoothstep(_ x: Float, edge0: Float, edge1: Float) -> Float {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    /// Interpolate between two prompts using weighted concatenation.
    /// Returns: "(1-t)% prompt1, t% prompt2" for semantic blending.
    private func interpolatePrompts(_ p1: String, _ p2: String, t: Float) -> String {
        let tClamped = t.clamped(to: 0...1)

        // Pure phase (no interpolation needed)
        if tClamped < 0.01 { return p1 }
        if tClamped > 0.99 { return p2 }

        // Weighted text interpolation
        let pct1 = Int((1 - tClamped) * 100)
        let pct2 = Int(tClamped * 100)

        // Blend: higher percentage = dominant prompt
        if pct1 > pct2 {
            return "\(pct1)% \(p1), \(pct2)% \(p2)"
        } else {
            return "\(pct2)% \(p2), \(pct1)% \(p1)"
        }
    }
}

// MARK: - Float Clamping Helper

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Feedback Loop Node

/// Audio feedback node implementing the whitepaper §3.3 recursive formula:
/// S(i+1) = ACE(S(i) + F(S(i)), T(i))
///
/// This is the ONLY node that may create cycles in the graph.
/// It connects spectral processing (F) with neural inference (ACE) to create
/// the recursive feedback loop that defines the Latent Resonator sound.
///
/// Architecture:
/// - Audio thread: real-time DSP, reads/writes circular buffers
/// - Inference Task: async ACE calls, triggered when buffer has enough samples
/// - Lock-free SPSC communication between threads
final class FeedbackLoopNode: BaseGraphNode {

    // MARK: - Parameters

    var delayTime: Float {
        get { getParam("delayTime", default: 0.1) }
        set { setParam("delayTime", value: newValue) }
    }

    var feedback: Float {
        get { getParam("feedback", default: 0.5) }
        set { setParam("feedback", value: newValue) }
    }

    /// Target buffer size for inference triggering (~1 second)
    var inferenceBufferSize: Int {
        get { getParam("inferenceBufferSize", default: Int(LRConstants.sampleRate)) }
        set { setParam("inferenceBufferSize", value: newValue) }
    }

    // MARK: - v2.0 Recursive Loop State (Whitepaper §3.3)

    /// Circular buffer for incoming audio from spectral chain (S(i) + F(S(i)))
    /// Single-producer: audio thread writes
    /// Single-consumer: inference Task reads
    private let captureBuffer: CircularAudioBuffer

    /// Circular buffer for processed audio from ACE (S(i+1))
    /// Single-producer: inference Task writes
    /// Single-consumer: audio thread reads
    private let feedbackBuffer: CircularAudioBuffer

    /// Backup loop buffer for sustain between inference cycles
    /// When feedbackBuffer drains, we read from here to keep audio flowing
    private var loopBuffer: [Float]
    private var loopWritePos: Int = 0
    private var loopReadPos: Int = 0
    private var loopSampleCount: Int = 0
    private let loopCapacity: Int

    /// Iteration counter for recursive formula (exposed for SequencerNode subscription)
    @Published var iterationCount: Int = 0

    /// Inference state
    private var isInferring: Bool = false
    private var consecutiveFailures: Int = 0
    private var inferenceTask: Task<Void, Never>?

    /// Reference to connected ACE inference node (for parameter sync)
    private weak var inferenceNode: ACEStepInferenceNode?

    /// Sample rate for calculations
    private let sampleRate: Double

    /// Audio format for node creation
    private let format: AVAudioFormat

    // MARK: - Init

    init(id: UUID = UUID(),
         params: [String: Any] = [:],
         sampleRate: Double = LRConstants.sampleRate,
         inferenceNode: ACEStepInferenceNode? = nil) {
        self.sampleRate = sampleRate
        self.inferenceNode = inferenceNode

        // Initialize circular buffers for async communication
        // Capacity: 2 seconds of audio at 48kHz
        self.captureBuffer = CircularAudioBuffer(capacity: Int(sampleRate * 2.0))
        self.feedbackBuffer = CircularAudioBuffer(capacity: Int(sampleRate * 2.0))

        // Loop buffer for sustain between inference cycles
        self.loopCapacity = Int(sampleRate * 2.0)
        self.loopBuffer = [Float](repeating: 0, count: loopCapacity)

        // Audio format
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!

        super.init(
            id: id,
            nodeType: "feedback_loop",
            category: .neural,
            displayName: "FEEDBACK LOOP"
        )

        for (key, value) in params {
            parameters[key] = value
        }

        // Start inference loop
        startInferenceLoop()
    }
    
    required init(from decoder: Decoder) throws {
        let sr = LRConstants.sampleRate
        self.sampleRate = sr
        
        self.captureBuffer = CircularAudioBuffer(capacity: Int(sr * 2.0))
        self.feedbackBuffer = CircularAudioBuffer(capacity: Int(sr * 2.0))
        
        self.loopCapacity = Int(sr * 2.0)
        self.loopBuffer = [Float](repeating: 0, count: loopCapacity)
        
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: sr,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        
        try super.init(from: decoder)
        
        // inferenceNode will be connected at runtime
        startInferenceLoop()
    }

    deinit {
        stopInferenceLoop()
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "feedback_in", label: "FB IN", signalType: .audio, direction: .input),
            NodePort(id: "delay_cv", label: "DELAY CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output),
            NodePort(id: "status", label: "STATUS", signalType: .control, direction: .output)
        ]
    }

    // MARK: - Audio Unit

    private var sourceNode: AVAudioSourceNode?

    override func audioUnit() -> AVAudioNode? {
        if sourceNode == nil {
            createSourceNode()
        }
        return sourceNode
    }

    private func createSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard ablPointer.count >= 2 else { return OSStatus(kAudio_ParamError) }

            let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)

            // Read from feedback buffer (S(i+1) from ACE)
            var outputSamples = [Float](repeating: 0, count: Int(frameCount))
            let readCount = self.feedbackBuffer.read(into: &outputSamples, count: Int(frameCount))

            // If feedback buffer underruns, read from loop buffer (sustain)
            if readCount < Int(frameCount) {
                for i in readCount..<Int(frameCount) {
                    if self.loopSampleCount > 0 {
                        outputSamples[i] = self.loopBuffer[self.loopReadPos]
                        self.loopReadPos = (self.loopReadPos + 1) % self.loopCapacity
                    } else {
                        outputSamples[i] = 0
                    }
                }
            }

            // Apply feedback amount
            let fb = min(self.feedback, 0.99)
            for i in 0..<Int(frameCount) {
                outputSamples[i] *= fb
            }

            // Write to output (stereo)
            for i in 0..<Int(frameCount) {
                leftPtr[i] = outputSamples[i]
                rightPtr[i] = outputSamples[i]
            }

            return noErr
        }
    }

    // MARK: - Audio Input Interface

    /// Receive processed audio from spectral chain (S(i) + F(S(i)))
    /// Called by upstream node via tap.
    ///
    /// - Parameter samples: Audio buffer from spectral chain output
    func receiveSpectralAudio(_ samples: [Float]) {
        // Write to capture buffer for inference
        captureBuffer.write(samples)
    }

    /// Install tap on upstream spectral node to receive audio input.
    ///
    /// - Parameters:
    ///   - upstreamNode: The upstream AVAudioNode (typically SpectralChainNode's sourceNode)
    ///   - engine: The AVAudioEngine for tap installation
    func installUpstreamTap(from upstreamNode: AVAudioNode, in engine: AVAudioEngine) {
        upstreamNode.removeTap(onBus: 0)

        upstreamNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { [weak self] buffer, _ in
            guard let self = self else { return }

            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            // Feed to our capture buffer
            self.receiveSpectralAudio(samples)
        }
    }

    // MARK: - Inference Loop (Whitepaper §3.3)

    /// Start the async inference loop that implements the recursive formula.
    /// This runs on a background Task and communicates with the audio thread
    /// via lock-free circular buffers.
    private func startInferenceLoop() {
        guard inferenceTask == nil else { return }

        inferenceTask = Task(priority: .low) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.runInferenceCycle()
                // Yield to let audio thread breathe
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
    }

    private func stopInferenceLoop() {
        inferenceTask?.cancel()
        inferenceTask = nil
    }

    /// Run one iteration of the recursive formula: S(i+1) = ACE(S(i) + F(S(i)), T(i))
    ///
    /// This implements the whitepaper §3.3 formula in the graph context.
    ///
    /// Recursive audio lineage:
    ///   - Lucier: I Am Sitting in a Room (1969) — recursive room acoustics
    ///   - Roads: Computer Music Tutorial (1996) — Chapter 10 on analysis/resynthesis
    private func runInferenceCycle() async {
        let needed = inferenceBufferSize
        let available = captureBuffer.availableToRead

        guard available >= needed else { return }

        // 1. Read captured audio (S(i) + F(S(i)))
        var inputSamples = [Float](repeating: 0, count: needed)
        let _ = captureBuffer.read(into: &inputSamples, count: needed)

        // 2. Signal inference in progress
        await MainActor.run { [weak self] in
            self?.isInferring = true
        }

        // 3. Get current parameters from connected inference node or use local
        let params = await snapshotParameters()

        // 4. Inject entropy (whitepaper §4.2.2)
        let noiseScale = params.entropy * 0.5
        if noiseScale > 0.0001 {
            for i in 0..<inputSamples.count {
                inputSamples[i] += SignalGenerator.boxMullerNoise() * noiseScale
            }
        }

        // 5. Run ACE inference
        var processedSamples: [Float] = []

        if let inference = inferenceNode,
           consecutiveFailures < 3,
           params.inputStrength > 0.0001 {
            // Accumulate and trigger inference
            inference.accumulate(inputSamples)

            // Read back processed audio (non-blocking)
            // ACEStepInferenceNode processes asynchronously
            // We read whatever is available in its output buffer
            try? await Task.sleep(nanoseconds: 100_000_000) // Brief delay for ACE processing (100ms)
            processedSamples = inference.read(needed)
        }

        // 6. Fallback: if no processed audio, use input (passthrough)
        if processedSamples.isEmpty || processedSamples.count < needed {
            processedSamples = inputSamples
        }

        // 7. Write to feedback buffer (S(i+1))
        feedbackBuffer.write(processedSamples)

        // 8. Copy to loop buffer for sustain
        let copyCount = min(processedSamples.count, loopCapacity)
        processedSamples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            for i in 0..<copyCount {
                loopBuffer[(loopWritePos + i) % loopCapacity] = base[i]
            }
        }
        loopWritePos = (loopWritePos + copyCount) % loopCapacity
        loopSampleCount = copyCount

        // 9. Update iteration counter
        iterationCount += 1

        await MainActor.run { [weak self] in
            self?.isInferring = false
        }
    }

    // MARK: - Parameter Snapshot

    /// Thread-safe parameter snapshot for inference.
    /// Mirrors the parameter snapshot pattern used across the v2.0 architecture.
    private struct InferenceParams {
        let prompt: String
        let cfg: Float
        let entropy: Float
        let grain: Float
        let steps: Int
        let inputStrength: Float
    }

    private func snapshotParameters() async -> InferenceParams {
        // Read from connected inference node if available
        if let inference = inferenceNode {
            return InferenceParams(
                prompt: inference.prompt,
                cfg: inference.guidanceScale,
                entropy: inference.entropy,
                grain: inference.granularity,
                steps: inference.numSteps,
                inputStrength: inference.inputStrength
            )
        }

        // Fallback to local parameters
        return InferenceParams(
            prompt: "",
            cfg: LRConstants.cfgScaleDefault,
            entropy: 0.25,
            grain: 0.45,
            steps: LRConstants.aceStepsDefault,
            inputStrength: LRConstants.inputStrengthDefault
        )
    }

    // MARK: - Control Interface

    /// Connect to an ACEStepInferenceNode for parameter synchronization.
    func connectInferenceNode(_ node: ACEStepInferenceNode) {
        self.inferenceNode = node
    }

    /// Reset all recursive state.
    func reset() {
        iterationCount = 0
        consecutiveFailures = 0
        captureBuffer.reset()
        feedbackBuffer.reset()
        loopWritePos = 0
        loopReadPos = 0
        loopSampleCount = 0
        for i in 0..<loopCapacity {
            loopBuffer[i] = 0
        }
    }
}

// MARK: - Prompt Bank Node

/// Editable dictionary of prompt strings, accessible via dot-notation keys.
/// Replaces hardcoded P1/P2/P3 and DrumVoice arrays with user-extensible bank.
///
/// Philosophy (Research — Envion Shell):
/// Prompts as tactical commands: .kick, .pad_warm, .drone_metal
/// User builds their own semantic vocabulary over time.
///
/// D4 Implementation: Per-lane curation — each lane has its own bank
/// ensuring drum lanes only see percussion prompts, pad lanes only pads, etc.
final class PromptBankNode: BaseGraphNode {
    
    // MARK: - Bank Dictionary
    
    /// The prompt bank: key → description mapping
    /// Keys use dot notation for categorization (.kick, .pad_warm, etc.)
    @Published var bank: [String: String] = [:]
    
    /// Active key. Changes when sequencer sends text signal via setActiveKey().
    @Published var activeKey: String = ".kick"
    
    /// History of recently used keys for quick recall (last 10)
    @Published var recentKeys: [String] = []
    
    // MARK: - Factory Presets
    
    /// Factory presets organized by category.
    /// Each lane loads relevant subset (drum lanes → percussion, etc.)
    static let factoryBank: [String: String] = [
        // Percussion (from DrumVoice)
        ".kick": "sub-bass pulse, metallic decay, 60Hz resonance",
        ".snare": "noise burst, spectral snap, transient attack",
        ".hat": "high-pass noise, metallic shimmer, 8kHz peak",
        ".tom": "tuned resonance, wooden timbre, pitch decay",
        ".crash": "broadband noise, chaotic spectrum, long decay",
        ".ride": "bell-like overtones, sustained ring, metallic",
        
        // Pads (from P1/P2/P3 concept)
        ".pad_warm": "analog chorus, spectral drift, warm saturation",
        ".pad_cold": "digital shimmer, ice crystal texture, high-pass",
        ".pad_evolving": "recursive feedback, spectral memory, slow drift",
        
        // Basses
        ".bass_moog": "ladder filter sweep, resonance buildup, sub-bass",
        ".bass_acid": "303 squelch, resonance peak, filter modulation",
        ".bass_sub": "pure sine, sub-harmonic generation, 40Hz",
        
        // Textures
        ".drone_metal": "harmonic saturation, comb filter metallic, sustained",
        ".texture_granular": "microsound windows, grain cloud, temporal smearing",
        ".texture_ferrofluid": "liquid metal, viscous motion, magnetic pull",
        
        // Chaos
        ".chaos_low": "controlled drift, slight hallucination, 60% coherence",
        ".chaos_high": "deep saturation, recursive hallucination, 10% coherence",
        ".chaos_pure": "silence input, pure latent prior, model unconscious"
    ]
    
    /// Filter keys by category prefix (e.g., ".kick" for percussion)
    static func keysForCategory(_ category: String, in bank: [String: String]) -> [String] {
        bank.keys.filter { $0.hasPrefix(".\(category)") }.sorted()
    }
    
    // MARK: - Init
    
    init(id: UUID = UUID(), initialBank: [String: String]? = nil) {
        super.init(
            id: id,
            nodeType: "prompt_bank",
            category: .neural,
            displayName: "PROMPT BANK"
        )
        
        // Load initial bank (factory or custom)
        self.bank = initialBank ?? Self.factoryBank
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // bank and activeKey will be loaded by Codable
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "prompt_out", label: "PROMPT", signalType: .control, direction: .output),
            NodePort(id: "key_in", label: "KEY", signalType: .control, direction: .input),
            NodePort(id: "active_cv", label: "ACTIVE", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Text Evaluation
    
    /// Return the active prompt for downstream ACE inference nodes.
    /// Called by connected nodes to retrieve current prompt text.
    func evaluateText(portId: String) -> String? {
        guard portId == "prompt_out" else { return nil }
        return bank[activeKey] ?? "spectral texture"
    }
    
    /// Return active key as a control signal (0.0-1.0 based on key index)
    func evaluateControl(portId: String, at time: TimeInterval) -> Float {
        guard portId == "active_cv" else { return 0.0 }
        
        let keys = Array(bank.keys).sorted()
        guard let index = keys.firstIndex(of: activeKey) else { return 0.0 }
        
        // Normalize to 0.0-1.0 range
        return Float(index) / Float(max(keys.count - 1, 1))
    }
    
    // MARK: - Bank Management
    
    /// Set active key from incoming text signal (e.g., from sequencer).
    /// Validates key exists in bank.
    func setActiveKey(_ key: String) {
        guard bank.keys.contains(key) else {
            print("PromptBankNode: key '\(key)' not found in bank")
            return
        }
        
        // Update recent keys (move to front, cap at 10)
        recentKeys.removeAll { $0 == key }
        recentKeys.insert(key, at: 0)
        if recentKeys.count > 10 {
            recentKeys = Array(recentKeys.prefix(10))
        }
        
        self.activeKey = key
        objectWillChange.send()
    }
    
    /// Add or update prompt in bank.
    /// Validates key format (must start with dot).
    func setPrompt(key: String, value: String) {
        guard key.hasPrefix(".") else {
            print("PromptBankNode: keys must start with dot (e.g., '.kick')")
            return
        }
        
        bank[key] = value
        objectWillChange.send()
    }
    
    /// Remove prompt from bank.
    /// Cannot remove if it's the only key or the active key.
    func removePrompt(key: String) -> Bool {
        // Prevent removing last key
        guard bank.count > 1 else {
            print("PromptBankNode: cannot remove last key")
            return false
        }
        
        // Prevent removing active key
        guard key != activeKey else {
            print("PromptBankNode: cannot remove active key")
            return false
        }
        
        bank.removeValue(forKey: key)
        recentKeys.removeAll { $0 == key }
        objectWillChange.send()
        return true
    }
    
    /// Get prompts filtered by category prefix.
    /// e.g., category "kick" returns [.kick, .kick_room, .kick_sub, etc.]
    func promptsForCategory(_ category: String) -> [String: String] {
        bank.filter { $0.key.hasPrefix(".\(category)") }
    }
    
    /// Reset to factory presets.
    func resetToFactory() {
        self.bank = Self.factoryBank
        self.activeKey = ".kick"
        self.recentKeys = []
        objectWillChange.send()
    }
    
    /// Import bank from dictionary (for per-lane curation / preset loading).
    func importBank(_ newBank: [String: String], merge: Bool = false) {
        if merge {
            for (key, value) in newBank {
                bank[key] = value
            }
        } else {
            bank = newBank
        }
        
        // Ensure active key still exists
        if !bank.keys.contains(activeKey), let firstKey = bank.keys.sorted().first {
            activeKey = firstKey
        }
        
        objectWillChange.send()
    }
    
    /// Export current bank for serialization.
    func exportBank() -> [String: String] {
        bank
    }
}
