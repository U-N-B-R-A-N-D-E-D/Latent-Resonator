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
            nodeType: "oscillator",
            category: .source,
            displayName: "OSCILLATOR"
        )
        
        // Apply initial parameters
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
            NodePort(id: "freq_cv", label: "FREQ CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, audioBufferList in
            guard let self = self else { return OSStatus(kAudio_ParamError) }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard ablPointer.count >= 2 else { return OSStatus(kAudio_ParamError) }

            let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)

            // Update generator parameters from node parameters
            self.generator.sineFrequency = self.frequency
            self.generator.pulseWidth = self.pulseWidth
            self.generator.euclideanPulses = self.euclideanPulses
            self.generator.euclideanSteps = self.euclideanSteps
            self.generator.pulseDensity = self.pulseDensity

            // Render audio
            self.generator.renderInto(
                left: leftPtr,
                right: rightPtr,
                frameCount: Int(frameCount),
                mode: self.waveform,
                sampleRate: self.format.sampleRate
            )

            // Apply amplitude scaling
            let amp = self.amplitude
            for i in 0..<Int(frameCount) {
                leftPtr[i] *= amp
                rightPtr[i] *= amp
            }

            return noErr
        }
    }
    
    // MARK: - Topology
    
    func onTopologyChanged(inputs: [String: GraphEdge], outputs: [String: [GraphEdge]]) {
        // If freq_cv is connected, CV modulation will be applied by ModulationGraphEvaluator
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
            nodeType: "noise",
            category: .source,
            displayName: "NOISE"
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
            NodePort(id: "amp_cv", label: "AMP CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }
    
    private func createSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, audioBufferList in
            guard let self = self else { return OSStatus(kAudio_ParamError) }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard ablPointer.count >= 2 else { return OSStatus(kAudio_ParamError) }
            
            let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)
            
            // Render white noise
            self.generator.renderInto(
                left: leftPtr,
                right: rightPtr,
                frameCount: Int(frameCount),
                mode: .whiteNoise,
                sampleRate: self.format.sampleRate
            )
            
            // Apply amplitude scaling
            let amp = self.amplitude
            if amp != 1.0 {
                for i in 0..<Int(frameCount) {
                    leftPtr[i] *= amp
                    rightPtr[i] *= amp
                }
            }
            
            return noErr
        }
    }
}

// MARK: - Audio Input Node

/// External audio input (mic/line).
/// Wraps AVAudioEngine's inputNode.
final class AudioInputNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var gain: Float {
        get { getParam("gain", default: 1.0) }
        set { setParam("gain", value: newValue) }
    }
    
    // MARK: - Internal State
    
    private weak var engineInputNode: AVAudioInputNode?
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:], engineInputNode: AVAudioInputNode?) {
        self.engineInputNode = engineInputNode
        
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
        // engineInputNode is runtime-only, will be reconnected by AudioGraphMapper
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return engineInputNode
    }
}

// MARK: - Koenig Seed Node (Whitepaper §4.1)

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
    
    /// AVAudioSourceNode reference
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
            nodeType: "koenig_seed",
            category: .source,
            displayName: "KOENIG SEED"
        )
        
        // Apply initial parameters
        for (key, value) in params {
            parameters[key] = value
        }
        
        // Initialize rhythm
        updateRhythm()
        createSourceNode()
    }
    
    required init(from decoder: Decoder) throws {
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        try super.init(from: decoder)
        updateRhythm()
        createSourceNode()
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "gate", label: "GATE", signalType: .gate, direction: .input),
            NodePort(id: "clk", label: "CLK", signalType: .gate, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Audio Unit
    
    override func audioUnit() -> AVAudioNode? {
        return sourceNode
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
    
    private func createSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, audioBufferList in
            guard let self = self else { return OSStatus(kAudio_ParamError) }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard ablPointer.count >= 2 else { return OSStatus(kAudio_ParamError) }
            
            let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)
            
            // Clear buffer
            memset(leftPtr, 0, Int(frameCount) * MemoryLayout<Float>.size)
            memset(rightPtr, 0, Int(frameCount) * MemoryLayout<Float>.size)
            
            // Check gate
            guard self.gateOpen || !self.gated else {
                return noErr
            }
            
            // Determine step duration in samples
            let stepsPerSecond: Double
            if self.clockRate > 0 {
                stepsPerSecond = Double(self.clockRate)
            } else {
                stepsPerSecond = Double(self.tempo) / 60.0 // beats per second (quarter notes)
            }
            
            let samplesPerStep = Int(self.sampleRate / stepsPerSecond)
            guard samplesPerStep > 0 else { return noErr }
            
            // Convert ms to samples
            let decaySamples = Int((Double(self.impulseDecay) / 1000.0) * self.sampleRate)
            let tailSamples = Int((Double(self.tailDuration) / 1000.0) * self.sampleRate)
            
            // Generate events
            for i in 0..<Int(frameCount) {
                // Advance step counter
                let totalSample = Int(timestamp.pointee.mSampleTime) + i
                let currentStepIndex = (totalSample / samplesPerStep) % self.rhythmPattern.count
                
                // Check if we're at the start of a step
                let isStepStart = (totalSample % samplesPerStep) == 0
                
                // Check if this step has an impulse
                let shouldTrigger = isStepStart && 
                                   self.rhythmPattern[currentStepIndex] &&
                                   Float.random(in: 0...1) < self.eventProbability * self.nucleationDensity
                
                if shouldTrigger {
                    // Generate Dirac impulse with decay
                    self.generateImpulse(at: i, 
                                        left: leftPtr, 
                                        right: rightPtr, 
                                        frameCount: Int(frameCount),
                                        decaySamples: decaySamples,
                                        tailSamples: tailSamples)
                }
            }
            
            return noErr
        }
    }
    
    /// Generate a single nucleation event (impulse + noise tail)
    private func generateImpulse(at index: Int, 
                                  left: UnsafeMutablePointer<Float>,
                                  right: UnsafeMutablePointer<Float>,
                                  frameCount: Int,
                                  decaySamples: Int,
                                  tailSamples: Int) {
        let impulseAmp = self.impulseAmplitude
        let tailAmp = self.tailAmplitude * impulseAmp
        let decayFactor = self.tailDecay
        
        // Generate impulse with exponential decay
        for i in 0..<min(decaySamples + tailSamples, frameCount - index) {
            let sampleIndex = index + i
            let t = Double(i)
            
            var sample: Float
            if i < decaySamples {
                // Impulse phase - exponential decay
                let decay = exp(-t / (Double(decaySamples) * 0.3))
                sample = impulseAmp * Float(decay)
            } else {
                // Tail phase - Gaussian noise with exponential decay
                let tailIndex = i - decaySamples
                let gauss = Float.random(in: -1...1) // Simplified Gaussian
                let tailIndexF = Float(tailIndex)
                let tailSamplesF = Float(tailSamples)
                let decayConstant = tailIndexF / (tailSamplesF * decayFactor)
                let tailDecay = exp(-decayConstant)
                sample = tailAmp * gauss * tailDecay
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
    
    /// Reset pattern to start position
    func reset() {
        stepIndex = 0
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
