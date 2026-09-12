import Foundation
import AVFoundation
import Combine

// MARK: - Oscillator Node

/// Multi-waveform oscillator source node.
/// Wraps SignalGenerator's waveform modes (sine, saw, square, triangle, pulse, Koenig seed).
final class OscillatorNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var waveform: ExcitationMode {
        get { getParam("waveform", default: ExcitationMode.sineOsc) }
        set { setParam("waveform", value: newValue) }
    }
    
    var frequency: Float {
        get { getParam("frequency", default: LRConstants.sineFrequencyDefault) }
        set { setParam("frequency", value: newValue) }
    }
    
    var amplitude: Float {
        get { getParam("amplitude", default: 0.5) }
        set { setParam("amplitude", value: newValue) }
    }
    
    var pulseWidth: Float {
        get { getParam("pulseWidth", default: LRConstants.pulseWidthDefault) }
        set { setParam("pulseWidth", value: newValue) }
    }
    
    var euclideanPulses: Int {
        get { getParam("euclideanPulses", default: LRConstants.euclideanPulses) }
        set { setParam("euclideanPulses", value: newValue) }
    }
    
    var euclideanSteps: Int {
        get { getParam("euclideanSteps", default: LRConstants.euclideanSteps) }
        set { setParam("euclideanSteps", value: newValue) }
    }
    
    var pulseDensity: Float {
        get { getParam("pulseDensity", default: LRConstants.pulseDensityDefault) }
        set { setParam("pulseDensity", value: newValue) }
    }
    
    // MARK: - Internal State

    private var generator = SignalGenerator()

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "oscillator",
            category: .source,
            displayName: "OSCILLATOR"
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
            NodePort(id: "freq_cv", label: "FREQ CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Topology

    func onTopologyChanged(inputs: [String: GraphEdge], outputs: [String: [GraphEdge]]) {
        // CV modulation (if freq_cv is connected) is applied by the
        // ControlGraphEvaluator via `setParameter`/`getParam` per block.
    }

    // MARK: - Koenig Seed Manual Trigger (Manifesto: "Listen before you adjust")
    //
    // When this oscillator is in `.koenigSeed` mode, START must NOT auto-fire
    // the Euclidean seed. The performer arms it manually. No-op for other
    // waveforms (saw/sine/square/etc. keep their existing behavior — the
    // manifesto fix targets only the Koenig seed injection path).
    @discardableResult
    func triggerSeed() -> Bool {
        guard waveform == .koenigSeed else { return false }
        return generator.triggerKoenigSeed()
    }

    /// Whether the Koenig seed is currently armed (UI introspection).
    /// Always `false` for non-koenig waveforms.
    var isSeedArmed: Bool {
        guard waveform == .koenigSeed else { return false }
        return generator.koenigArmed
    }
}

// MARK: - OscillatorNode + DSPNode (GraphAudioEngine integration)

extension OscillatorNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // P1.5 — snapshot every getParam read into a local before the
        // DSP body. A knob drag on the main thread mutates `parameters`
        // (a COW dict); re-reading mid-render would force a heap alloc on
        // the audio thread. Locals are immutable value types — no COW.
        let freq = frequency
        let pw = pulseWidth
        let ep = euclideanPulses
        let es = euclideanSteps
        let pd = pulseDensity
        let wave = waveform
        let amp = amplitude

        generator.sineFrequency = freq
        generator.pulseWidth = pw
        generator.euclideanPulses = ep
        generator.euclideanSteps = es
        generator.pulseDensity = pd

        generator.renderInto(
            left: output.left,
            right: output.right,
            frameCount: frameCount,
            mode: wave,
            sampleRate: sampleRate
        )

        if amp != 1.0 {
            for i in 0..<frameCount {
                output.left[i] *= amp
                output.right[i] *= amp
            }
        }
    }
}

// MARK: - Noise Node

/// White noise generator.
/// Broadband excitation source for spectral processing.
final class NoiseNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var amplitude: Float {
        get { getParam("amplitude", default: 0.3) }
        set { setParam("amplitude", value: newValue) }
    }
    
    // MARK: - Internal State
    
    private var generator = SignalGenerator()

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "noise",
            category: .source,
            displayName: "NOISE"
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
            NodePort(id: "amp_cv", label: "AMP CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
}

// MARK: - NoiseNode + DSPNode

extension NoiseNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        generator.renderInto(
            left: output.left,
            right: output.right,
            frameCount: frameCount,
            mode: .whiteNoise,
            sampleRate: sampleRate
        )

        let amp = amplitude
        if amp != 1.0 {
            for i in 0..<frameCount {
                output.left[i] *= amp
                output.right[i] *= amp
            }
        }
    }
}

// MARK: - Audio Input Node

/// External audio input (mic/line) fed by the shared `CircularAudioBuffer`
/// in `NeuralEngine`. Reads from the lock-free SPSC ring on the audio
/// thread and applies a gain stage.
final class AudioInputNode: BaseGraphNode {

    // MARK: - Parameters

    var gain: Float {
        get { getParam("gain", default: 1.0) }
        set { setParam("gain", value: newValue) }
    }

    // MARK: - Internal State

    /// Shared ring buffer fed by the hardware input tap. Single producer
    /// (input tap), single consumer (this node's `render()`).
    private var audioInputBuffer: CircularAudioBuffer?

    /// Legacy AVAudioInputNode reference (unused by the pull-render engine
    /// but kept for any future AudioUnit-style path).
    private weak var engineInputNode: AVAudioInputNode?

    /// Consecutive underflow counter; kept for diagnostics but never blocks.
    private var underflowCount: Int = 0

    // MARK: - Init

    init(
        id: UUID = UUID(),
        params: [String: Any] = [:],
        engineInputNode: AVAudioInputNode? = nil,
        audioInputBuffer: CircularAudioBuffer? = nil
    ) {
        self.engineInputNode = engineInputNode
        self.audioInputBuffer = audioInputBuffer

        super.init(
            id: id,
            nodeType: "audio_input",
            category: .source,
            displayName: "AUDIO IN"
        )

        for (key, value) in params {
            parameters[key] = value
        }
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // audioInputBuffer is injected at runtime by NeuralEngine/NodeFactory.
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Audio Unit (legacy, not used by the pull-render engine)

    override func audioUnit() -> AVAudioNode? {
        return engineInputNode
    }
}

// MARK: - AudioInputNode + DSPNode

extension AudioInputNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        let g = gain
        let buf = audioInputBuffer

        // Read whatever the ring buffer has, then zero-pad the rest.
        let read = buf?.read(into: output.left, count: frameCount) ?? 0
        if read < frameCount {
            underflowCount += 1
            let remaining = frameCount - read
            let offset = output.left.advanced(by: read)
            let bytes = remaining * MemoryLayout<Float>.stride
            memset(offset, 0, bytes)
        }

        // Apply gain to both channels (mono source → stereo output).
        if g != 1.0 {
            for i in 0..<frameCount {
                output.left[i] *= g
            }
        }
        for i in 0..<frameCount {
            output.right[i] = output.left[i]
        }
    }

    func reset() {
        underflowCount = 0
    }
}

// MARK: - Koenig Seed Node (Whitepaper §4.1)
//
// Algorithmic composition lineage:
//   - Koenig: Project One/Two (1960s) — algorithmic composition via stochastic selection
//   - Xenakis: GENDYN (1971) — dynamic stochastic synthesis
//   - Roads: Automated granular orchestration (Microsound, 2001)
//
/// Dirac impulse generator with Euclidean rhythm distribution E(k,n).
/// Creates "nucleation sites" for the diffusion model - sparse excitation events
/// followed by Gaussian noise tails to seed the denoiser.
///
/// Parameters:
/// - E(k,n): Euclidean rhythm defining pulse distribution
/// - impulseDecay: Duration of the main Dirac impulse (ms)
/// - tailDuration: Gaussian noise tail length (ms)
/// - tailAmplitude: Relative amplitude of noise tail
/// - nucleationDensity: Probability multiplier for event generation
/// - primeSteps: Force n to be prime (maximal evenness)
/// - syncMode: Free running or clock synchronized
///
/// Algorithm: Bjorklund's algorithm for maximal evenness distribution.
/// Prime step counts (13, 17, 19) avoid Western metric symmetry.
final class KoenigSeedNode: BaseGraphNode {
    
    // MARK: - E(k,n) Parameters
    
    /// Number of pulses (k in E(k,n))
    var pulses: Int {
        get { getParam("pulses", default: 5) }
        set { 
            setParam("pulses", value: max(1, min(newValue, steps)))
            updateRhythm()
        }
    }
    
    /// Number of steps (n in E(k,n))
    var steps: Int {
        get { getParam("steps", default: 13) }
        set {
            setParam("steps", value: max(1, newValue))
            // Ensure pulses <= steps
            if pulses > newValue {
                parameters["pulses"] = newValue
            }
            updateRhythm()
        }
    }
    
    /// Rotation offset for the pattern (shifts pulse positions)
    var rotation: Int {
        get { getParam("rotation", default: 0) }
        set { 
            setParam("rotation", value: newValue)
            updateRhythm()
        }
    }
    
    // MARK: - Impulse Character
    
    /// Main impulse decay time in milliseconds (sharpness)
    var impulseDecay: Float {
        get { getParam("impulseDecay", default: 5.0) }
        set { setParam("impulseDecay", value: max(0.1, min(newValue, 100.0))) }
    }
    
    /// Amplitude of the main impulse (0.0...1.0)
    var impulseAmplitude: Float {
        get { getParam("impulseAmplitude", default: 0.8) }
        set { setParam("impulseAmplitude", value: max(0.0, min(newValue, 1.0))) }
    }
    
    // MARK: - Noise Tail Parameters
    
    /// Duration of Gaussian tail in milliseconds
    var tailDuration: Float {
        get { getParam("tailDuration", default: 20.0) }
        set { setParam("tailDuration", value: max(0.0, min(newValue, 200.0))) }
    }
    
    /// Relative amplitude of noise tail vs impulse (0.0...1.0)
    var tailAmplitude: Float {
        get { getParam("tailAmplitude", default: 0.3) }
        set { setParam("tailAmplitude", value: max(0.0, min(newValue, 1.0))) }
    }
    
    /// Tail exponential decay factor (higher = faster decay)
    var tailDecay: Float {
        get { getParam("tailDecay", default: 0.5) }
        set { setParam("tailDecay", value: max(0.01, min(newValue, 2.0))) }
    }
    
    // MARK: - Event Control
    
    /// Probability density multiplier (1.0 = normal, 0.0 = no events, 2.0 = double density)
    var nucleationDensity: Float {
        get { getParam("nucleationDensity", default: 1.0) }
        set { setParam("nucleationDensity", value: max(0.0, min(newValue, 3.0))) }
    }
    
    /// Probability of event passing (0.0...1.0) - for sparse patterns
    var eventProbability: Float {
        get { getParam("eventProbability", default: 1.0) }
        set { setParam("eventProbability", value: max(0.0, min(newValue, 1.0))) }
    }
    
    /// Gate input enabled - only generate when gate is high
    var gated: Bool {
        get { getParam("gated", default: false) }
        set { setParam("gated", value: newValue) }
    }
    
    // MARK: - Timing
    
    /// Clock rate in Hz (0.0 = free running with internal tempo)
    var clockRate: Float {
        get { getParam("clockRate", default: 0.0) }
        set { setParam("clockRate", value: max(0.0, newValue)) }
    }
    
    /// Internal tempo in BPM when free running
    var tempo: Float {
        get { getParam("tempo", default: 120.0) }
        set { setParam("tempo", value: max(1.0, min(newValue, 999.0))) }
    }
    
    // MARK: - Advanced
    
    /// Force step count to nearest prime (maximal evenness per whitepaper)
    var primeSteps: Bool {
        get { getParam("primeSteps", default: true) }
        set {
            setParam("primeSteps", value: newValue)
            if newValue { adjustToPrime() }
        }
    }
    
    /// Randomize pulse distribution while maintaining cardinality
    var stochastic: Bool {
        get { getParam("stochastic", default: false) }
        set { setParam("stochastic", value: newValue) }
    }
    
    // MARK: - Internal State
    
    /// Cached Euclidean rhythm pattern
    private var rhythmPattern: [Bool] = []

    /// Current position in pattern
    private var stepIndex: Int = 0

    /// Sample rate for time calculations
    private let sampleRate: Double = Double(LRConstants.sampleRate)

    /// Current phase for clock generation
    private var phase: Double = 0.0

    /// Gate state
    private var gateOpen: Bool = true

    /// Manifesto gate ("Listen before you adjust"): false until the
    /// performer manually arms the seed via `triggerSeed()` (K key / UI
    /// button / MIDI). Defaults `false` so START does NOT auto-inject —
    /// the feedback loop runs silent (or passthrough) until the performer
    /// deliberately drops the seed. This is the surgical fix for the
    /// philosophy bug where pressing SPACE auto-fired the Koenig seed,
    /// contradicting the onboarding manifesto.
    private var seedArmed: Bool = false

    /// Cumulative sample counter across render blocks. Replaces the
    /// `mSampleTime` timestamp the old AVAudioSourceNode callback used to
    /// drive event scheduling — under the new pull-render model the engine
    /// invokes us with `frameCount` only, so we count samples ourselves.
    private var totalSamplesProcessed: Int = 0

    /// Lock-free PRNG for RT-safe stochastic generation (Xenakis/Koenig).
    /// Replaces `Float.random(in:)` (which uses the global Swift RNG and
    /// takes a lock — not audio-thread safe). Matches the contract already
    /// used by `SpectralPipeline` and `SignalGenerator`.
    private var rng = Xoshiro256StarStar()

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "koenig_seed",
            category: .source,
            displayName: "KOENIG SEED"
        )

        for (key, value) in params {
            parameters[key] = value
        }

        updateRhythm()
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        updateRhythm()
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "gate", label: "GATE", signalType: .gate, direction: .input),
            NodePort(id: "clk", label: "CLK", signalType: .gate, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Rhythm Management
    
    /// Compute Euclidean rhythm using Bjorklund's algorithm
    static func computeEuclideanRhythm(pulses k: Int, steps n: Int) -> [Bool] {
        guard k > 0, n > 0, k <= n else {
            return Array(repeating: false, count: max(n, 0))
        }
        
        var pattern: [[Bool]] = Array(repeating: [true], count: k)
        var remainder: [[Bool]] = Array(repeating: [false], count: n - k)
        
        while remainder.count > 1 {
            let take = min(pattern.count, remainder.count)
            var merged: [[Bool]] = []
            
            for i in 0..<take {
                merged.append(pattern[i] + remainder[i])
            }
            
            let leftoverPattern = Array(pattern.dropFirst(take))
            let leftoverRemainder = Array(remainder.dropFirst(take))
            
            pattern = merged
            remainder = leftoverPattern + leftoverRemainder
        }
        
        return (pattern + remainder).flatMap { $0 }
    }
    
    /// Find nearest prime number >= n
    private static let primes: [Int] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113]
    
    private func adjustToPrime() {
        let currentSteps = steps
        if let nearest = Self.primes.first(where: { $0 >= currentSteps }) {
            parameters["steps"] = nearest
            updateRhythm()
        }
    }
    
    private func updateRhythm() {
        var k = pulses
        let n = steps
        
        // Ensure k <= n
        if k > n { k = n }
        
        // Generate base pattern
        var pattern = Self.computeEuclideanRhythm(pulses: k, steps: n)
        
        // Apply rotation
        let rot = rotation % n
        if rot != 0 {
            pattern = Array(pattern[rot...] + pattern[..<rot])
        }
        
        rhythmPattern = pattern
        stepIndex = 0
    }
    
    // MARK: - Audio Generation

    /// Generate a single nucleation event (impulse + noise tail) into the
    /// caller-provided stereo output. Same DSP body as the v1
    /// AVAudioSourceNode path, just operating on engine-owned pointers.
    /// P1.5 — takes all user-facing params as arguments so the caller can
    /// snapshot them once at the top of `render` and we never re-read the
    /// COW `parameters` dict from the audio thread.
    fileprivate func generateImpulse(
        at index: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        decaySamples: Int,
        tailSamples: Int,
        impulseAmp: Float,
        tailAmp: Float,
        tailDecay: Float
    ) {
        let tailAmpScaled = tailAmp * impulseAmp

        for i in 0..<min(decaySamples + tailSamples, frameCount - index) {
            let sampleIndex = index + i
            let t = Double(i)

            var sample: Float
            if i < decaySamples {
                // Impulse phase — exponential decay
                let decay = exp(-t / (Double(decaySamples) * 0.3))
                sample = impulseAmp * Float(decay)
            } else {
                // Tail phase — Gaussian-ish noise with exponential decay
                let tailIndex = i - decaySamples
                let gauss = rng.nextGaussian(mean: 0, stddev: 1)
                let tailIndexF = Float(tailIndex)
                let tailSamplesF = Float(tailSamples)
                let decayConstant = tailIndexF / (tailSamplesF * tailDecay)
                let tailDecayVal = exp(-decayConstant)
                sample = tailAmpScaled * gauss * tailDecayVal
            }

            left[sampleIndex] += sample
            right[sampleIndex] += sample
        }
    }
    
    // MARK: - Control Interface
    
    /// Trigger a gate to enable generation
    func triggerGate() {
        gateOpen = true
    }

    /// Close gate to mute generation
    func closeGate() {
        gateOpen = false
    }

    /// Manifesto: arm/disarm the Koenig seed. Toggled by the performer
    /// (K key / UI button / MIDI). Until armed, `render` emits silence so
    /// the performer can listen to the empty feedback loop first. Returns
    /// the new armed state for UI feedback.
    @discardableResult
    func triggerSeed() -> Bool {
        seedArmed.toggle()
        return seedArmed
    }

    /// Whether the seed is currently armed (UI introspection).
    var isSeedArmed: Bool { seedArmed }

    /// Reset pattern to start position. Also implements `DSPNode.reset()`.
    func reset() {
        stepIndex = 0
        totalSamplesProcessed = 0
        phase = 0.0
    }
    
    /// Get current rhythm pattern for visualization
    func getPattern() -> [Bool] {
        return rhythmPattern
    }
    
    /// Set E(k,n) with validation
    func setEuclidean(pulses k: Int, steps n: Int) {
        let validN = max(1, n)
        let validK = max(1, min(k, validN))
        
        if primeSteps {
            // Adjust to nearest prime >= n
            if let primeN = Self.primes.first(where: { $0 >= validN }) {
                parameters["steps"] = primeN
                parameters["pulses"] = min(validK, primeN)
            } else {
                parameters["steps"] = validN
                parameters["pulses"] = validK
            }
        } else {
            parameters["steps"] = validN
            parameters["pulses"] = validK
        }
        
        updateRhythm()
    }
}

// MARK: - KoenigSeedNode + DSPNode

extension KoenigSeedNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // Always start by zeroing the buffer; events accumulate on top.
        let bytes = frameCount * MemoryLayout<Float>.stride
        memset(output.left, 0, bytes)
        memset(output.right, 0, bytes)

        // Manifesto ("Listen before you adjust"): the seed does NOT auto-fire
        // on START. The performer arms it manually via `triggerSeed()` (K key
        // / UI button / MIDI). Until armed, render emits silence — the
        // feedback loop runs empty so the performer can listen first.
        guard seedArmed else { return }

        // P1.5 — snapshot all user-facing params into locals before any
        // DSP work. A knob drag mid-block mutates `parameters` (COW dict);
        // re-reading it inside the loop would force a heap alloc on the
        // audio thread.
        let isGated = gated
        let clkRate = clockRate
        let bpm = tempo
        let impulseDecayMs = impulseDecay
        let tailDurationMs = tailDuration
        let eventProb = eventProbability
        let nucleation = nucleationDensity
        let impulseAmp = impulseAmplitude
        let tailAmp = tailAmplitude
        let tailDecayFactor = tailDecay

        // Gate honors the legacy semantics: when `gated == true`, the node
        // emits nothing unless `gateOpen == true`. Free-running mode bypasses
        // the gate entirely.
        if isGated && !gateOpen { return }

        // Step duration in samples — driven by either the external clock
        // rate or the internal tempo (BPM as quarter-notes-per-second).
        let stepsPerSecond: Double = clkRate > 0
            ? Double(clkRate)
            : Double(bpm) / 60.0

        let samplesPerStep = Int(self.sampleRate / stepsPerSecond)
        guard samplesPerStep > 0, !rhythmPattern.isEmpty else {
            totalSamplesProcessed += frameCount
            return
        }

        let decaySamples = Int((Double(impulseDecayMs) / 1000.0) * self.sampleRate)
        let tailSamples = Int((Double(tailDurationMs) / 1000.0) * self.sampleRate)
        let probability = eventProb * nucleation

        // Walk the buffer one sample at a time looking for step boundaries.
        // When the modulus aligns with the start of an "on" step in the
        // Euclidean pattern (and the probability roll succeeds), drop a
        // Dirac impulse + noise tail starting at that frame.
        for i in 0..<frameCount {
            let totalSample = totalSamplesProcessed + i
            let isStepStart = (totalSample % samplesPerStep) == 0
            guard isStepStart else { continue }

            let stepIdx = (totalSample / samplesPerStep) % rhythmPattern.count
            guard rhythmPattern[stepIdx] else { continue }
            guard rng.nextFloat(in: 0...1) < probability else { continue }

            generateImpulse(
                at: i,
                left: output.left,
                right: output.right,
                frameCount: frameCount,
                decaySamples: decaySamples,
                tailSamples: tailSamples,
                impulseAmp: impulseAmp,
                tailAmp: tailAmp,
                tailDecay: tailDecayFactor
            )
        }

        totalSamplesProcessed += frameCount
    }
}
