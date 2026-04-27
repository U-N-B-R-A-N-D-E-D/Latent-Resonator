import Foundation
import AVFoundation
import Accelerate
import Combine

// MARK: - FFT Analysis Node

/// Forward FFT with Hann windowing.
/// Converts time-domain audio → frequency-domain spectrum.
final class FFTAnalysisNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var fftSize: Int {
        get { getParam("fftSize", default: LRConstants.fftSize) }
        set { setParam("fftSize", value: newValue) }
    }
    
    // MARK: - Internal State
    
    private var halfN: Int
    private var fftLog2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var realPart: [Float]
    private var imagPart: [Float]
    private var hannWindow: [Float]
    private var chunkBuffer: [Float]
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        let size = (params["fftSize"] as? Int) ?? LRConstants.fftSize
        self.halfN = size / 2
        let log2 = Int(log2f(Float(size)))
        self.fftLog2n = vDSP_Length(log2)
        
        if let setup = vDSP_create_fftsetup(self.fftLog2n, FFTRadix(kFFTRadix2)) {
            self.fftSetup = setup
        }
        
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.chunkBuffer = [Float](repeating: 0, count: size)
        
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
        
        super.init(
            id: id,
            nodeType: "fft_analysis",
            category: .analysis,
            displayName: "FFT"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        let size = LRConstants.fftSize
        self.halfN = size / 2
        let log2 = Int(log2f(Float(size)))
        self.fftLog2n = vDSP_Length(log2)
        
        if let setup = vDSP_create_fftsetup(self.fftLog2n, FFTRadix(kFFTRadix2)) {
            self.fftSetup = setup
        } else {
            self.fftSetup = nil
        }
        
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.chunkBuffer = [Float](repeating: 0, count: size)
        
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.hannWindow = window
        
        try super.init(from: decoder)
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "out_real", label: "REAL", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    /// Process audio through FFT.
    /// Returns (real, imag) split-complex representation.
    func processSpectrum(samples: [Float]) -> (real: [Float], imag: [Float]) {
        guard let setup = fftSetup else {
            return (Array(repeating: 0, count: halfN), Array(repeating: 0, count: halfN))
        }
        
        let size = fftSize
        
        // Copy input to chunk buffer with zero-padding if needed
        for i in 0..<size {
            chunkBuffer[i] = i < samples.count ? samples[i] : 0
        }
        
        // Apply Hann window
        vDSP_vmul(chunkBuffer, 1, hannWindow, 1, &chunkBuffer, 1, vDSP_Length(size))
        
        // Pack and transform
        packForFFT(chunkBuffer)
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                guard let realBase = realBuf.baseAddress, let imagBase = imagBuf.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zrip(setup, &splitComplex, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        
        return (realPart, imagPart)
    }
    
    private func packForFFT(_ data: [Float]) {
        for i in 0..<halfN {
            realPart[i] = data[2 * i]
            imagPart[i] = data[2 * i + 1]
        }
    }
}

// MARK: - Semantic EQ Node

/// 4-band spectral profile derived from prompt keywords.
/// The "Semantic Filter" from white paper §6.1.
final class SemanticEQNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var prompt: String {
        get { getParam("prompt", default: "") }
        set {
            setParam("prompt", value: newValue)
            updateProfile(from: newValue)
        }
    }
    
    var fallbackProfile: [Float] {
        get { getParam("fallbackProfile", default: [1.0, 1.0, 1.0, 1.0]) }
        set { setParam("fallbackProfile", value: newValue) }
    }
    
    // MARK: - State
    
    private var spectralProfile: [Float] = [1.0, 1.0, 1.0, 1.0]
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "semantic_eq",
            category: .analysis,
            displayName: "SEMANTIC EQ"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
        
        if let promptParam = params["prompt"] as? String {
            updateProfile(from: promptParam)
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // spectralProfile initialized to default in declaration
        if let promptParam = parameters["prompt"] as? String {
            updateProfile(from: promptParam)
        }
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "out_real", label: "REAL OUT", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    /// Apply 4-band spectral profile to split-complex spectrum.
    func processSpectrum(real: inout [Float], imag: inout [Float]) {
        let halfN = real.count
        let bandSize = halfN / 4
        
        for band in 0..<4 {
            let gain = spectralProfile[band]
            let start = band * bandSize
            let end = (band == 3) ? halfN : (band + 1) * bandSize
            
            for i in start..<end {
                real[i] *= gain
                imag[i] *= gain
            }
        }
    }
    
    private func updateProfile(from prompt: String) {
        var accum: [Float] = [0, 0, 0, 0]
        var matches = 0
        
        let lowered = prompt.lowercased()
        for (keyword, gains) in LRConstants.semanticProfiles where lowered.contains(keyword) {
            for i in 0..<4 { accum[i] += gains[i] }
            matches += 1
        }
        
        if matches > 0 {
            for i in 0..<4 { accum[i] /= Float(matches) }
            spectralProfile = accum
        } else {
            spectralProfile = fallbackProfile
        }
    }
}

// MARK: - Spectral Saturation Node

/// Per-band harmonic enrichment (spectral distortion).
/// Higher CFG → more spectral nonlinearity.
final class SpectralSaturationNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var guidanceScale: Float {
        get { getParam("guidanceScale", default: 10.0) }
        set { setParam("guidanceScale", value: newValue) }
    }
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "spectral_saturation",
            category: .analysis,
            displayName: "SPECTRAL SAT"
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
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "cfg_cv", label: "CFG CV", signalType: .control, direction: .input),
            NodePort(id: "out_real", label: "REAL OUT", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    func processSpectrum(real: inout [Float], imag: inout [Float]) {
        guard guidanceScale > 5.0 else { return }
        
        let halfN = real.count
        let bandSize = halfN / 4
        let satFactor = (guidanceScale - 5.0) / 15.0
        
        for band in 0..<4 {
            let start = band * bandSize
            let end = (band == 3) ? halfN : (band + 1) * bandSize
            
            for i in start..<end {
                let mag = sqrtf(real[i] * real[i] + imag[i] * imag[i])
                let phase = atan2f(imag[i], real[i])
                
                let saturated = tanhf(mag * (1.0 + satFactor))
                real[i] = saturated * cosf(phase)
                imag[i] = saturated * sinf(phase)
            }
        }
    }
}

// MARK: - Spectral Noise Node

/// Inject colored Gaussian noise in frequency domain.
/// Creates nucleation sites for timbral structures (§4.1.3).
final class SpectralNoiseNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var entropyLevel: Float {
        get { getParam("entropyLevel", default: 0.0) }
        set { setParam("entropyLevel", value: newValue) }
    }
    
    // MARK: - State
    
    private var rng = Xoshiro256StarStar()
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "spectral_noise",
            category: .analysis,
            displayName: "SPECTRAL NOISE"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // rng initialized with default value
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "entropy_cv", label: "ENTROPY CV", signalType: .control, direction: .input),
            NodePort(id: "out_real", label: "REAL OUT", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    func processSpectrum(real: inout [Float], imag: inout [Float]) {
        guard entropyLevel > 0.001 else { return }
        
        let level = entropyLevel * 0.01
        
        for i in 0..<real.count {
            let noiseReal = rng.nextGaussian() * level
            let noiseImag = rng.nextGaussian() * level
            real[i] += noiseReal
            imag[i] += noiseImag
        }
    }
}

// MARK: - Spectral Memory Node

/// Recursive spectral blending (drift accumulation).
/// The DSP analogue of latent state persistence.
final class SpectralMemoryNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var feedbackAmount: Float {
        get { getParam("feedbackAmount", default: 0.5) }
        set { setParam("feedbackAmount", value: newValue) }
    }
    
    var memoryCoeff: Float {
        get { getParam("memoryCoeff", default: 0.85) }
        set { setParam("memoryCoeff", value: newValue) }
    }
    
    // MARK: - State
    
    private var spectralMemory: [Float] = []
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "spectral_memory",
            category: .analysis,
            displayName: "SPECTRAL MEMORY"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // spectralMemory initialized as empty array
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "feedback_cv", label: "FEEDBACK CV", signalType: .control, direction: .input),
            NodePort(id: "out_real", label: "REAL OUT", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    func processSpectrum(real: inout [Float], imag: inout [Float]) {
        let halfN = real.count
        
        // Initialize memory if needed
        if spectralMemory.count != halfN {
            spectralMemory = [Float](repeating: 0, count: halfN)
        }
        
        // Compute magnitude
        var magnitude = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            magnitude[i] = sqrtf(real[i] * real[i] + imag[i] * imag[i])
        }
        
        // Blend with memory
        let blend = feedbackAmount
        for i in 0..<halfN {
            spectralMemory[i] = memoryCoeff * spectralMemory[i] + (1.0 - memoryCoeff) * magnitude[i]
            let blended = (1.0 - blend) * magnitude[i] + blend * spectralMemory[i]
            
            let phase = atan2f(imag[i], real[i])
            real[i] = blended * cosf(phase)
            imag[i] = blended * sinf(phase)
        }
    }
}

// MARK: - Spectral Granularity Node

/// Stochastic spectral bin masking (microsound sparsification).
final class SpectralGranularityNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var granularity: Float {
        get { getParam("granularity", default: 0.0) }
        set { setParam("granularity", value: newValue) }
    }
    
    // MARK: - State
    
    private var rng = Xoshiro256StarStar()
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "spectral_granularity",
            category: .analysis,
            displayName: "GRANULARITY"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // rng initialized with default value
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "grain_cv", label: "GRAIN CV", signalType: .control, direction: .input),
            NodePort(id: "out_real", label: "REAL OUT", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    func processSpectrum(real: inout [Float], imag: inout [Float]) {
        guard granularity > 0.01 else { return }
        
        let prob = granularity * 0.01
        
        for i in 0..<real.count {
            if rng.nextFloat() > prob {
                real[i] = 0
                imag[i] = 0
            }
        }
    }
}

// MARK: - Spectral Freeze Node

/// Captures and sustains a spectral snapshot (§5.2 Saturation).
final class SpectralFreezeNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var freezeActive: Bool {
        get { getParam("freezeActive", default: false) }
        set { setParam("freezeActive", value: newValue) }
    }
    
    var blendAmount: Float {
        get { getParam("blendAmount", default: 0.5) }
        set { setParam("blendAmount", value: newValue) }
    }
    
    // MARK: - State
    
    private var frozenReal: [Float]?
    private var frozenImag: [Float]?
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "spectral_freeze",
            category: .analysis,
            displayName: "SPECTRAL FREEZE"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // frozenReal and frozenImag are nil by default
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "freeze_gate", label: "FREEZE", signalType: .gate, direction: .input),
            NodePort(id: "out_real", label: "REAL OUT", signalType: .control, direction: .output),
            NodePort(id: "out_imag", label: "IMAG OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    func processSpectrum(real: inout [Float], imag: inout [Float]) {
        if freezeActive {
            if frozenReal == nil {
                frozenReal = real
                frozenImag = imag
            }
            
            if let frozen_r = frozenReal, let frozen_i = frozenImag, frozen_r.count == real.count {
                let blend = blendAmount
                for i in 0..<real.count {
                    real[i] = (1.0 - blend) * real[i] + blend * frozen_r[i]
                    imag[i] = (1.0 - blend) * imag[i] + blend * frozen_i[i]
                }
            }
        } else {
            frozenReal = nil
            frozenImag = nil
        }
    }
}

// MARK: - IFFT Synthesis Node

/// Inverse FFT converting frequency-domain spectrum back to audio.
final class IFFTSynthesisNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    var fftSize: Int {
        get { getParam("fftSize", default: LRConstants.fftSize) }
        set { setParam("fftSize", value: newValue) }
    }
    
    // MARK: - Internal State
    
    private var halfN: Int
    private var fftLog2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var realPart: [Float]
    private var imagPart: [Float]
    private var outputBuffer: [Float]
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        let size = (params["fftSize"] as? Int) ?? LRConstants.fftSize
        self.halfN = size / 2
        let log2 = Int(log2f(Float(size)))
        self.fftLog2n = vDSP_Length(log2)
        
        if let setup = vDSP_create_fftsetup(self.fftLog2n, FFTRadix(kFFTRadix2)) {
            self.fftSetup = setup
        }
        
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.outputBuffer = [Float](repeating: 0, count: size)
        
        super.init(
            id: id,
            nodeType: "ifft_synthesis",
            category: .analysis,
            displayName: "IFFT"
        )
        
        for (key, value) in params {
            parameters[key] = value
        }
    }
    
    required init(from decoder: Decoder) throws {
        let size = LRConstants.fftSize
        self.halfN = size / 2
        let log2 = Int(log2f(Float(size)))
        self.fftLog2n = vDSP_Length(log2)
        
        if let setup = vDSP_create_fftsetup(self.fftLog2n, FFTRadix(kFFTRadix2)) {
            self.fftSetup = setup
        } else {
            self.fftSetup = nil
        }
        
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.outputBuffer = [Float](repeating: 0, count: size)
        
        try super.init(from: decoder)
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
    
    // MARK: - Ports
    
    override var ports: [NodePort] {
        [
            NodePort(id: "in_real", label: "REAL IN", signalType: .control, direction: .input),
            NodePort(id: "in_imag", label: "IMAG IN", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
    
    // MARK: - Processing
    
    func processSpectrum(real: [Float], imag: [Float]) -> [Float] {
        guard let setup = fftSetup else {
            return Array(repeating: 0, count: fftSize)
        }
        
        // Copy input to working buffers
        for i in 0..<min(halfN, real.count) {
            realPart[i] = real[i]
            imagPart[i] = imag[i]
        }
        
        // Inverse FFT
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                guard let realBase = realBuf.baseAddress, let imagBase = imagBuf.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zrip(setup, &splitComplex, 1, fftLog2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        
        // Unpack
        unpackFromFFT(&outputBuffer)
        
        // Normalize (vDSP requires 1/(2N) scaling)
        var scale = 1.0 / Float(fftSize * 2)
        vDSP_vsmul(outputBuffer, 1, &scale, &outputBuffer, 1, vDSP_Length(fftSize))
        
        return outputBuffer
    }
    
    private func unpackFromFFT(_ data: inout [Float]) {
        for i in 0..<halfN {
            data[2 * i] = realPart[i]
            data[2 * i + 1] = imagPart[i]
        }
    }
}

// MARK: - Spectral Chain Node

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
    
    // MARK: - v2.0 Real Audio Input (Ring Buffer)
    
    /// Circular buffer for receiving audio from upstream nodes.
    /// Written by AudioGraphMapper.installUpstreamTap(), read by sourceNode render callback.
    /// Lock-free SPSC design for audio-thread safety.
    private let inputRingBuffer: CircularAudioBuffer
    
    /// Capacity: 2 seconds of audio at 48kHz = 96000 samples.
    /// Actual latency depends on tap callback timing (typically < 100ms).
    private static let inputBufferCapacity = 96000
    
    // MARK: - v2.0 Spectral Pipeline (8-Stage)
    
    /// Semantic profile cache (4-band EQ: [low, lowMid, highMid, high])
    /// Updated when prompt parameter changes
    private var cachedSemanticProfile: [Float] = [0, 0, 0, 0]
    
    // Audio unit
    private var sourceNode: AVAudioSourceNode?
    private let format: AVAudioFormat

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

        // Initialize v2.0 ring buffer BEFORE super.init (required for Swift init rules)
        self.inputRingBuffer = CircularAudioBuffer(capacity: Self.inputBufferCapacity)
        
        // Initialize v2.0 spectral pipeline
        self.analysisPipeline = SpectralPipeline(fftSize: size, sampleRate: sampleRate)

        let fmt = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        self.format = fmt

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

        createSourceNode()
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
        
        self.inputRingBuffer = CircularAudioBuffer(capacity: Self.inputBufferCapacity)
        self.analysisPipeline = SpectralPipeline(fftSize: size, sampleRate: sr)
        
        let fmt = AVAudioFormat(
            standardFormatWithSampleRate: sr,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!
        self.format = fmt
        
        try super.init(from: decoder)
        
        // Initialize semantic profile cache from decoded parameters
        cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
        
        createSourceNode()
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

    // MARK: - Audio Unit

    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }

    // MARK: - Parameter Changes

    override func onParameterChanged(key: String, value: Any) {
        // Most parameters are passed directly to pipeline.process() in audio callback
        // However, prompt changes require rebuilding the semantic profile cache
        if key == "semanticProfile" || key == "prompt" {
            cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
        }
    }

    /// Reset all processing state.
    /// Called when the audio engine is restarted or the node is reconfigured.
    func reset() {
        analysisPipeline?.reset()
        cachedSemanticProfile = buildSemanticProfile(from: semanticProfile)
    }

    // MARK: - Source Node Creation

    private func createSourceNode() {
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard ablPointer.count >= 2 else { return OSStatus(kAudio_ParamError) }

            let leftPtr = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            let rightPtr = ablPointer[1].mData!.assumingMemoryBound(to: Float.self)

            // v2.0: Read from input ring buffer (fed by upstream nodes via tap)
            // Audio-thread safe: lock-free SPSC ring buffer
            var inputSamples = [Float](repeating: 0, count: Int(frameCount))
            let readCount = self.inputRingBuffer.read(into: &inputSamples, count: Int(frameCount))

            // If buffer underruns (not enough audio from upstream), pad with zeros
            // This provides graceful degradation rather than crash/glitch
            if readCount < Int(frameCount) {
                for i in readCount..<Int(frameCount) {
                    inputSamples[i] = 0.0
                }
            }

            // v2.0: Process through 8-stage spectral pipeline
            // Whitepaper alignment: FFT→SemanticEQ→Saturation→Noise→Memory→Granularity→Freeze→IFFT
            let processed = self.processSpectralPipeline(input: inputSamples)

            // Copy to stereo output
            for i in 0..<min(processed.count, Int(frameCount)) {
                leftPtr[i] = processed[i]
                rightPtr[i] = processed[i]
            }

            return noErr
        }
    }

    // MARK: - v2.0 Spectral Pipeline Processing

    /// Process audio through the complete 8-stage spectral pipeline.
    ///
    /// - Parameter input: Input audio buffer
    /// - Returns: Processed audio buffer (same length as input)
    private func processSpectralPipeline(input: [Float]) -> [Float] {
        // Build semantic profile from prompt parameter (C.3: Map semantic profile)
        let profile = cachedSemanticProfile.isEmpty
            ? buildSemanticProfile(from: semanticProfile)
            : cachedSemanticProfile

        // Call extracted pipeline with whitepaper-aligned parameters
        // C.1: §5.2 Saturation parameters → saturationAmount
        // C.2: §5.4 Metallic Sheen is handled by comb filter (separate node)
        guard let pipeline = analysisPipeline else { return input }
        return pipeline.process(
            input: input,
            semanticProfile: profile,
            saturationAmount: saturationAmount,
            noiseAmount: noiseAmount,
            memoryCoefficient: memoryCoeff,
            granularity: granularity,
            freezeActive: freezeActive,
            freezeBlend: freezeBlend
        )
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

    // MARK: - v2.0 Audio Input Interface

    /// Called by AudioGraphMapper to feed audio from upstream connections.
    /// This is how audio actually enters the spectral chain.
    ///
    /// - Parameter samples: Audio buffer from upstream node (via tap)
    func feedAudio(_ samples: [Float]) {
        // Write to circular buffer (lock-free, audio-thread safe)
        // SPSC: tap callback (producer) writes, render callback (consumer) reads
        inputRingBuffer.write(samples)
    }

    /// Called by AudioGraphMapper when this node is connected to an upstream source.
    /// Installs a tap on the upstream node's output to feed our input buffer.
    ///
    /// - Parameters:
    ///   - upstreamNode: The upstream AVAudioNode to tap
    ///   - engine: The AVAudioEngine for tap installation
    func installUpstreamTap(from upstreamNode: AVAudioNode, in engine: AVAudioEngine) {
        // Remove existing tap if any (defensive, should not exist for fresh connections)
        upstreamNode.removeTap(onBus: 0)

        // Install tap to feed our input buffer
        // Buffer size 4096 is a good balance between latency and CPU efficiency
        upstreamNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Extract mono samples from buffer
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

            // Feed to our input ring buffer
            self.feedAudio(samples)
        }
    }
}
