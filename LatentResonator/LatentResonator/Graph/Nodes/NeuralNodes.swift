import Foundation
import Combine
import os

// MARK: - ACE-Step Inference Node

/// Parameter surface for ACE-Step inference. Does NOT conform to `DSPNode` /
/// `GraphNodeDSPProvider` and is silently skipped by `ExecutionPlan.build` —
/// it never touches an audio buffer. The connected `FeedbackLoopNode` (the
/// only neural-adjacent `DSPNode`) reads a parameter snapshot from this node
/// through a weak reference and calls `ACEStepBridge.infer(...)` itself, off
/// the audio thread. Keeping inference out of this node's `render` path is
/// intentional: a synchronous `await bridge.infer(...)` here would block the
/// audio thread for the multi-second inference duration.
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

    /// ACE-Step §6.1 attention allocation. 1.0 = structure, 10.0 = detail.
    /// Surfaced by `ACEStepInferenceCard` and forwarded to the Python server
    /// via `FeedbackLoopNode.snapshotParameters()` -> `bridge.infer(...)`.
    var shift: Float {
        get { getParam("shift", default: LRConstants.aceShiftDefault) }
        set { setParam("shift", value: newValue) }
    }

    /// ACE-Step §6.1 inference method. `"ode"` (deterministic) or `"sde"`
    /// (stochastic). Mirrored from the Python server's `infer_method` field.
    var inferMethod: String {
        get { getParam("inferMethod", default: LRConstants.aceInferMethodDefault) }
        set { setParam("inferMethod", value: newValue) }
    }

    /// ACE-Step §6.1 per-step denoise amount (0 = none, 1 = full). The app
    /// already skips the bridge entirely when this is 0; non-zero values
    /// must reach the server for the parameter to mean anything.
    var denoiseStrength: Float {
        get { getParam("denoiseStrength", default: LRConstants.denoiseStrengthDefault) }
        set { setParam("denoiseStrength", value: newValue) }
    }

    // MARK: - Bridge

    /// Shared ACE-Step bridge, injected by `NodeFactory` at construction time
    /// (mirrors `FeedbackLoopNode.bridge`). Exposed (not `private`) so
    /// `NodeGraph`'s topology-wiring pass can (re)assign it idempotently.
    weak var bridge: ACEStepBridge?

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
        let modelLoaded = bridge?.isModelLoaded ?? false
        return NodeTelemetry(
            rmsLevel: 0.0,
            spectralCentroid: 0.0,
            spectralFlatness: 0.0,
            level: modelLoaded ? 1.0 : 0.0,
            isActive: modelLoaded,
            cpuUsage: 0.0
        )
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

/// Real-time DSPNode implementing the whitepaper §3.3 recursive formula:
/// S(i+1) = ACE(S(i) + N(μ,σ), P, γ)
///
/// This is the ONLY node that may create cycles in the graph, and the ONLY
/// neural-adjacent node that participates in the audio render graph
/// (`GraphNodeDSPProvider` / `DSPNode` below). `ACEStepInferenceNode` is a
/// parameter surface read through `inferenceNode` — it never runs inference
/// itself.
///
/// Architecture (hybrid, see the `v2-node-graph` / `audio-thread-safety` skills):
/// - `render()` — audio thread. Pointer-based `captureBuffer.write` +
///   `feedbackBuffer.read` only, plus a cheap `os_unfair_lock_trylock`
///   check to fire at most one inference cycle at a time. No allocation,
///   no `await`, no blocking.
/// - `runInferenceCycle()` — triggered async `Task`, off the audio thread.
///   Awaits `bridge.infer(...)` for real and writes the result back into
///   `feedbackBuffer` for a future `render()` call to pick up.
/// - Lock-free SPSC `CircularAudioBuffer`s carry audio across the boundary.
final class FeedbackLoopNode: BaseGraphNode {

    // MARK: - Parameters

    var delayTime: Float {
        get { getParam("delayTime", default: 0.1) }
        set { setParam("delayTime", value: newValue) }
    }

    /// Loop gain applied to the inference-cycle output before it re-enters
    /// the mix. Capped below 1.0 to keep the recirculating signal stable —
    /// same convention as `DelayLineNode`/`CombFilterNode`.
    var feedback: Float {
        get { getParam("feedback", default: 0.5) }
        set { setParam("feedback", value: newValue) }
    }

    /// Target buffer size for inference triggering (~1 second)
    var inferenceBufferSize: Int {
        get { getParam("inferenceBufferSize", default: Int(LRConstants.sampleRate)) }
        set { setParam("inferenceBufferSize", value: newValue) }
    }

    // MARK: - Recursive Loop State (Whitepaper §3.3)

    /// Incoming audio captured for the next inference cycle (S(i)).
    /// Single-producer: audio thread writes in `render()`.
    /// Single-consumer: the triggered inference `Task` reads.
    private let captureBuffer: CircularAudioBuffer

    /// Processed audio from the last completed inference cycle (S(i+1)).
    /// Single-producer: the inference `Task` writes.
    /// Single-consumer: audio thread reads in `render()`.
    private let feedbackBuffer: CircularAudioBuffer

    /// Iteration counter for recursive formula (exposed for SequencerNode subscription)
    @Published var iterationCount: Int = 0

    /// Outcome of the most recently *completed* inference cycle. UI-facing
    /// counterpart to the `print(">> FeedbackLoop: ...")` lines below --
    /// those only ever reached the Xcode console, so there was no way to
    /// see success/failure without it open. `.idle` until the first cycle
    /// completes; never reset back to `.idle` afterwards so the last result
    /// stays visible (a transient flash is easy to miss mid-performance).
    enum InferOutcome: Equatable {
        case idle
        case success(iteration: Int, at: Date)
        case failure(reason: String, at: Date)
    }
    @Published var lastOutcome: InferOutcome = .idle

    /// Non-nil while an `/infer` HTTP call is actually in flight (set right
    /// before `bridge.infer(...)`, cleared on completion/failure). Distinct
    /// from `isInferringLock`, which also covers buffer bookkeeping around
    /// the call -- this is specifically "is the neural round-trip running
    /// right now", for a UI "RUNNING (elapsed)" readout.
    @Published var inferenceStartedAt: Date?

    /// Wall-clock duration (ms) of the most recently *completed* inference
    /// round-trip. Used by the UI to show the cost of the last neural cycle
    /// (e.g. an "elapsed" readout). Zero until the first cycle completes;
    /// never reset, so the last value stays visible.
    @Published var lastInferenceDurationMs: Double = 0

    /// Guards against spawning more than one inference `Task` at a time.
    /// `withLockIfAvailable` from `render()` (never blocks the audio
    /// thread); `withLock` from the async `runInferenceCycle()`'s `defer`
    /// (`OSAllocatedUnfairLock`, unlike raw `os_unfair_lock`, is safe to
    /// use from an async context).
    private let isInferringLock = OSAllocatedUnfairLock(initialState: false)
    private var consecutiveFailures: Int = 0
    private var currentInferenceTask: Task<Void, Never>?

    // MARK: - Arrival Crossfade State (real-time safe)
    //
    // When a new inference result lands in `feedbackBuffer`, the output
    // must crossfade from the recirculating dry input into the new
    // neural output — a hard cut produces an audible click and breaks
    // the Lucier illusion of continuous recursive drift. The ramp is
    // driven entirely from `render()` (audio thread only, no locks).
    //
    // `xfadeSamplesRemaining` counts down each render block; while > 0
    // the output is `dry*(1-r) + fb*r` with `r` going 0→1. When it hits
    // 0 the new inference output is fully "in" and the dry input is
    // fully "out". A second ramp (`xfadeOutSamplesRemaining`) covers
    // the feedbackBuffer→dry transition at the tail of the buffer so
    // the hand-off back to the recirculating signal is also click-free.
    //
    // Equal-power crossfade would be nicer perceptually, but linear is
    // chosen here for branch-free DSP and to keep the fix surgical.
    private static let xfadeDurationSamples: Int = max(64, Int(LRConstants.sampleRate * 0.08)) // ~80ms
    private var xfadeInSamplesRemaining: Int = 0
    private var xfadeOutSamplesRemaining: Int = 0
    private var wasReadingFeedback: Bool = false

    /// Reference to the connected ACE inference node (parameter surface only).
    private weak var inferenceNode: ACEStepInferenceNode?

    /// Shared ACE-Step bridge, injected by `NodeFactory` / `NodeGraph`'s
    /// topology-wiring pass. `render()` degrades to passthrough when nil.
    weak var bridge: ACEStepBridge?

    /// Sample rate for buffer sizing.
    private let sampleRate: Double

    // MARK: - Init

    init(id: UUID = UUID(),
         params: [String: Any] = [:],
         sampleRate: Double = LRConstants.sampleRate,
         inferenceNode: ACEStepInferenceNode? = nil,
         bridge: ACEStepBridge? = nil) {
        self.sampleRate = sampleRate
        self.inferenceNode = inferenceNode
        self.bridge = bridge

        // Circular buffers for async communication. Capacity: 2 seconds of
        // audio at 48kHz — comfortably larger than any realistic
        // inferenceBufferSize so a slow inference cycle can't overrun it.
        self.captureBuffer = CircularAudioBuffer(capacity: Int(sampleRate * 2.0))
        self.feedbackBuffer = CircularAudioBuffer(capacity: Int(sampleRate * 2.0))

        super.init(
            id: id,
            nodeType: "feedback_loop",
            category: .neural,
            displayName: "FEEDBACK LOOP"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        let sr = LRConstants.sampleRate
        self.sampleRate = sr

        self.captureBuffer = CircularAudioBuffer(capacity: Int(sr * 2.0))
        self.feedbackBuffer = CircularAudioBuffer(capacity: Int(sr * 2.0))

        try super.init(from: decoder)

        // inferenceNode / bridge connected at runtime by NodeGraph's wiring pass.
    }

    deinit {
        currentInferenceTask?.cancel()
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

    // MARK: - Inference Trigger (Whitepaper §3.3)

    /// Checks the capture buffer and fires at most one inference `Task`.
    /// Called from `render()`; itself real-time safe — the only thing it
    /// does beyond the trylock/flag dance is spawn a `Task`, which is a
    /// cheap, non-blocking runtime call.
    /// P1.5 — `bufferSize` is snapshotted by the caller in `render` so we
    /// don't re-read the COW `parameters` dict here.
    private func triggerInferenceIfNeeded(bufferSize: Int) {
        guard captureBuffer.availableToRead >= bufferSize else { return }

        let shouldTrigger = isInferringLock.withLockIfAvailable { isInferring -> Bool in
            guard !isInferring else { return false }
            isInferring = true
            return true
        } ?? false
        guard shouldTrigger else { return }

        currentInferenceTask = Task(priority: .utility) { [weak self] in
            await self?.runInferenceCycle()
        }
    }

    /// Run one iteration of the recursive formula: S(i+1) = ACE(S(i) + N(μ,σ), P, γ)
    ///
    /// Runs entirely off the audio thread. This is the only place in the
    /// class that `await`s anything — `render()` never blocks on it.
    ///
    /// Recursive audio lineage:
    ///   - Lucier: I Am Sitting in a Room (1969) — recursive room acoustics
    ///   - Roads: Computer Music Tutorial (1996) — Chapter 10 on analysis/resynthesis
    private func runInferenceCycle() async {
        defer {
            isInferringLock.withLock { isInferring in
                isInferring = false
            }
        }

        let needed = inferenceBufferSize
        guard captureBuffer.availableToRead >= needed else { return }

        // 1. Read captured audio (S(i))
        var inputSamples = captureBuffer.read(count: needed)

        // 2. Current parameters from the connected ACEStepInferenceNode (or local defaults)
        let params = await snapshotParameters()

        // 3. Inject entropy (whitepaper §4.2.2)
        let noiseScale = params.entropy * 0.5
        if noiseScale > 0.0001 {
            for i in 0..<inputSamples.count {
                inputSamples[i] += SignalGenerator.boxMullerNoise() * noiseScale
            }
        }

        // 4. Run ACE inference for real. No bridge / no model / too many
        //    consecutive failures / inputStrength ~0 -> skip this cycle.
        //    render() already falls back to dry passthrough whenever
        //    feedbackBuffer has nothing new, so skipping here is a graceful
        //    no-op, not a failure state.
        guard let bridge = bridge else { return }

        // Bridge currently unreachable (disconnected, crashed, mid-restart --
        // see BridgeProcessManager's MPS crash latch) is NOT counted toward
        // consecutiveFailures. That counter only resets on a completed
        // success below, so without this reset, three drops in a row during
        // a routine bridge restart would permanently disable this node for
        // the rest of the session -- a node that never attempts inference
        // again can never land the success that would reset it. Health
        // polling / the crash-latch auto-relaunch own the reconnection
        // story; this just makes sure the node keeps trying once they land.
        guard bridge.status == .connected || bridge.status == .modelLoaded else {
            consecutiveFailures = 0
            return
        }

        guard consecutiveFailures < 3, params.inputStrength > 0.0001 else {
            return
        }

        // UI-visible "RUNNING" state starts here -- right before the actual
        // HTTP round-trip, not before the eligibility guards above (those
        // are silent no-ops, not "inferring").
        let inferStart = Date()
        await MainActor.run { [weak self] in self?.inferenceStartedAt = Date() }

        do {
            let processed = try await bridge.infer(
                samples: inputSamples,
                prompt: params.prompt,
                guidanceScale: params.cfg,
                numSteps: params.steps,
                inputStrength: params.inputStrength,
                entropy: params.entropy,
                granularity: params.grain,
                taskType: params.taskType,
                thinking: params.thinking,
                shift: params.shift,
                inferMethod: params.inferMethod,
                denoiseStrength: params.denoiseStrength
            )
            consecutiveFailures = 0

            // 5. Write S(i+1) for a future render() call to read.
            feedbackBuffer.write(processed)

            let sampleCount = processed.count
            let durationMs = Date().timeIntervalSince(inferStart) * 1000.0
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.iterationCount += 1
                self.inferenceStartedAt = nil
                self.lastInferenceDurationMs = durationMs
                self.lastOutcome = .success(iteration: self.iterationCount, at: Date())
                print(">> FeedbackLoop: ✓ infer complete -- \(sampleCount) samples written to feedbackBuffer (iteration \(self.iterationCount))")
            }
        } catch {
            consecutiveFailures += 1
            let reason = Self.shortFailureReason(error)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.inferenceStartedAt = nil
                self.lastOutcome = .failure(reason: reason, at: Date())
            }
            print(">> FeedbackLoop: ✗ infer failed (\(consecutiveFailures)/3 consecutive) -- \(error.localizedDescription)")
        }
    }

    /// Truncates an error's description to something that fits a one-line
    /// status strip instead of the full `URLError`/`ACEBridgeError` message.
    private static func shortFailureReason(_ error: Error) -> String {
        // "The network connection was lost" / "could not connect to server"
        // is what a dropped localhost socket looks like on the client side
        // when the bridge PROCESS dies mid-request (Metal/MPS abort, crash,
        // restart for a profile switch) -- there is no other network in
        // this picture (bridge binds 127.0.0.1 only, see the python-bridge
        // skill). Naming that plainly is a lot less alarming than the raw
        // NSURLError text, which reads like a Wi-Fi problem.
        if case ACEBridgeError.networkError(let underlying) = error,
           let urlError = underlying as? URLError,
           [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut].contains(urlError.code) {
            return "bridge unreachable -- reconnecting"
        }
        let msg = error.localizedDescription
        return msg.count > 48 ? String(msg.prefix(48)) + "…" : msg
    }

    // MARK: - Parameter Snapshot

    /// Thread-safe parameter snapshot for inference.
    /// Mirrors the parameter snapshot pattern used across the v2.0 architecture.
    ///
    /// Visibility is `internal` (not `private`) so `LatentResonatorTests` can
    /// pin the snapshot -> `InferenceParams` -> `bridge.infer(...)` path
    /// directly via `@testable import`. Not `public` — no external consumer.
    struct InferenceParams {
        let prompt: String
        let cfg: Float
        let entropy: Float
        let grain: Float
        let steps: Int
        let inputStrength: Float
        // §6.1 task-routing surface — the UI toggle/picker must reach the
        // Python server for these to mean anything.
        let taskType: String
        let thinking: Bool
        let shift: Float
        let inferMethod: String
        let denoiseStrength: Float
    }

    func snapshotParameters() async -> InferenceParams {
        // Read from connected inference node if available
        if let inference = inferenceNode {
            return InferenceParams(
                prompt: inference.prompt,
                cfg: inference.guidanceScale,
                entropy: inference.entropy,
                grain: inference.granularity,
                steps: inference.numSteps,
                inputStrength: inference.inputStrength,
                taskType: inference.taskType,
                thinking: inference.thinking,
                shift: inference.shift,
                inferMethod: inference.inferMethod,
                denoiseStrength: inference.denoiseStrength
            )
        }

        // Fallback to local parameters
        return InferenceParams(
            prompt: "",
            cfg: LRConstants.cfgScaleDefault,
            entropy: 0.25,
            grain: 0.45,
            steps: LRConstants.aceStepsDefault,
            inputStrength: LRConstants.inputStrengthDefault,
            taskType: LRConstants.aceTaskTypeDefault,
            thinking: LRConstants.aceThinkingDefault,
            shift: LRConstants.aceShiftDefault,
            inferMethod: LRConstants.aceInferMethodDefault,
            denoiseStrength: LRConstants.denoiseStrengthDefault
        )
    }

    // MARK: - Control Interface

    /// Connect to an ACEStepInferenceNode for parameter synchronization.
    /// Idempotent — safe to call repeatedly with the same node.
    func connectInferenceNode(_ node: ACEStepInferenceNode) {
        self.inferenceNode = node
    }
}

// MARK: - FeedbackLoopNode + DSPNode

extension FeedbackLoopNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // P1.5 — snapshot user-facing params into locals. `feedback` is read
        // for the recirculation gain below; `inferenceBufferSize` is read by
        // `triggerInferenceIfNeeded`. Both come from the COW `parameters`
        // dict — a knob drag mid-block would otherwise force a heap alloc
        // on the audio thread.
        let fb = min(feedback, LRConstants.feedbackCap)
        let inferSize = inferenceBufferSize

        // Port order: ExecutionPlan sorts connected audio inputs by
        // targetPortId. "feedback_in" < "in" alphabetically, so when both
        // are wired the primary signal is the LAST entry — never assume
        // inputs.first here.
        guard let inputBuffer = inputs.last else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        // Capture S(i) for the next inference cycle. Pointer-based, no
        // allocation — mono (left channel), matching the bridge's mono
        // contract and ACEStepBridge.infer's [Float] signature.
        captureBuffer.write(inputBuffer.left, count: frameCount)

        // Emit S(i) from the last completed inference cycle. Whatever the
        // ring buffer doesn't have yet falls back to the dry input — this
        // IS the "graceful passthrough" behavior when no model is loaded,
        // not a special case bolted on top.
        //
        // ARRIVAL CROSSFADE: when new inference output lands in
        // feedbackBuffer (transition from empty→non-empty), we ramp the
        // output from the recirculating dry input into the neural signal
        // over ~80ms. When the feedbackBuffer tail is reached (read <
        // frameCount at the end of the neural buffer), we ramp back into
        // the dry input over the same window. Both ramps prevent the
        // hard-cut clicks that would otherwise punctuate every cycle and
        // break the recursive-drift illusion. Real-time safe: only stack
        // scalars + a fixed-size VLA, no allocations, no locks.
        let read = feedbackBuffer.read(into: output.left, count: frameCount)

        // Detect new-arrival transition: empty → has data.
        if read > 0 && !wasReadingFeedback {
            xfadeInSamplesRemaining = Self.xfadeDurationSamples
        }
        // Detect tail transition: had data → partial/empty read this block.
        if wasReadingFeedback && read < frameCount {
            xfadeOutSamplesRemaining = Self.xfadeDurationSamples
        }
        wasReadingFeedback = read > 0

        let xfadeTotal = Float(Self.xfadeDurationSamples)

        // No scratch buffer: dry input is read directly from inputBuffer.left
        // (we write to output.left — a different buffer, so no aliasing).
        for i in 0..<frameCount {
            let dry = inputBuffer.left[i]
            // Neural signal: only defined for [0, read). Beyond that the
            // feedbackBuffer is exhausted and we hand off to dry input.
            var neural: Float = 0
            if i < read {
                let s = output.left[i] * fb
                neural = (s.isNaN || s.isInfinite) ? 0 : s
            }

            // Crossfade in (arrival): blend dry → neural.
            if xfadeInSamplesRemaining > 0 {
                let done = Float(Self.xfadeDurationSamples - xfadeInSamplesRemaining)
                let r = min(1.0, done / xfadeTotal)
                output.left[i] = dry * (1.0 - r) + neural * r
                xfadeInSamplesRemaining -= 1
                continue
            }
            // Crossfade out (tail): blend neural → dry.
            if xfadeOutSamplesRemaining > 0 && i >= read {
                let done = Float(Self.xfadeDurationSamples - xfadeOutSamplesRemaining)
                let r = min(1.0, done / xfadeTotal)
                output.left[i] = neural * (1.0 - r) + dry * r
                xfadeOutSamplesRemaining -= 1
                continue
            }
            // No active crossfade: hard route neural-or-dry.
            output.left[i] = (i < read) ? neural : dry
        }
        for i in 0..<frameCount {
            output.right[i] = output.left[i]
        }

        triggerInferenceIfNeeded(bufferSize: inferSize)
    }

    func reset() {
        iterationCount = 0
        consecutiveFailures = 0
        lastOutcome = .idle
        inferenceStartedAt = nil
        captureBuffer.reset()
        feedbackBuffer.reset()
        // Arrival-crossfade state — clear so a reset node doesn't resume
        // a stale ramp into the next cycle.
        xfadeInSamplesRemaining = 0
        xfadeOutSamplesRemaining = 0
        wasReadingFeedback = false
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
