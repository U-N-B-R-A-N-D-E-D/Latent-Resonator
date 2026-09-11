import Foundation
import AVFoundation
import Accelerate

// MARK: - Spectral Analyzer Node

/// Converts audio input into spectral feature control signals.
/// Performs FFT analysis and extracts centroid, flatness, and flux.
///
/// Real-time contract (audio thread):
/// - All working memory is pre-allocated in `init`/`init(from:)`.
/// - `render()` performs only scalar/array writes, one vDSP DFT execute,
///   and bounded spectral-math loops. No heap allocation, no locks, no I/O.
final class SpectralAnalyzerNode: BaseGraphNode {

    // MARK: - Parameters

    var fftSize: Int {
        get { getParam("fftSize", default: 2048) }
        set { setParam("fftSize", value: newValue) }
    }

    var smoothing: Float {
        get { getParam("smoothing", default: 0.8) }
        set { setParam("smoothing", value: newValue) }
    }

    // MARK: - State

    /// Pre-allocated accumulator for the next FFT block. Capacity == fftSize.
    private var accumulator: [Float] = []

    /// Number of valid samples currently in `accumulator`.
    private var accumulatorCount: Int = 0

    /// Real/imag output buffers for the forward DFT.
    private var realPart: [Float] = []
    private var imagPart: [Float] = []

    /// All-zeros imaginary input for real-input DFT.
    private var imagInput: [Float] = []

    /// Magnitude spectrum for the most recent frame.
    private var magnitudeSnapshot: [Float] = []

    /// Previous magnitude spectrum for flux computation.
    private var previousMagnitude: [Float] = []

    /// True once a previous magnitude frame has been stored; false after `reset()`.
    /// Prevents the first frame from being compared against an all-zero buffer.
    private var hasPreviousFrame: Bool = false

    /// Forward DFT setup (created once, reused forever).
    private var fftSetup: vDSP_DFT_Setup?

    /// Raw feature values from the latest frame.
    private var centroid: Float = 0.0
    private var flatness: Float = 0.0
    private var flux: Float = 0.0

    /// Exponentially-smoothed values exposed to the control graph.
    /// Torn reads are inaudible; the audio thread writes them, the main
    /// thread reads them at ~60Hz through `evaluateControl`.
    private(set) var smoothedCentroid: Float = 0.0
    private(set) var smoothedFlatness: Float = 0.0
    private(set) var smoothedFlux: Float = 0.0

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "spectral_analyzer",
            category: .analysis,
            displayName: "ANALYZER"
        )

        for (key, value) in params {
            parameters[key] = value
        }

        setupFFT()
    }

    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        setupFFT()
    }

    deinit {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "centroid", label: "CENTROID", signalType: .control, direction: .output),
            NodePort(id: "flatness", label: "FLATNESS", signalType: .control, direction: .output),
            NodePort(id: "flux", label: "FLUX", signalType: .control, direction: .output)
        ]
    }

    // MARK: - Telemetry

    override var telemetry: NodeTelemetry {
        NodeTelemetry(
            rmsLevel: 0.0,
            spectralCentroid: smoothedCentroid,
            spectralFlatness: smoothedFlatness,
            level: smoothedCentroid / 20000.0, // Normalize for display
            isActive: true,
            cpuUsage: 0.05
        )
    }

    // MARK: - Control Evaluation

    func evaluateControl(portId: String, at time: TimeInterval) -> Float {
        switch portId {
        case "centroid":
            return smoothedCentroid
        case "flatness":
            return smoothedFlatness
        case "flux":
            return smoothedFlux
        default:
            return 0.0
        }
    }

    // MARK: - FFT Analysis

    private func setupFFT() {
        let n = fftSize
        accumulator = [Float](repeating: 0, count: n)
        accumulatorCount = 0
        realPart = [Float](repeating: 0, count: n)
        imagPart = [Float](repeating: 0, count: n)
        imagInput = [Float](repeating: 0, count: n)
        magnitudeSnapshot = [Float](repeating: 0, count: n / 2)
        previousMagnitude = [Float](repeating: 0, count: n / 2)

        fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(n),
            vDSP_DFT_Direction.FORWARD
        )
    }

    /// Run one FFT frame and update the smoothed spectral features.
    /// Called from `render()` only when `accumulatorCount` reaches `fftSize`.
    ///
    /// - Parameter alpha: smoothing coefficient (snapshotted on the audio thread).
    private func analyzeFrame(alpha: Float) {
        guard let setup = fftSetup, accumulatorCount >= fftSize else { return }
        let halfN = fftSize / 2

        // Forward DFT: real input is the accumulator, imag input is zeros.
        vDSP_DFT_Execute(
            setup,
            &accumulator,
            &imagInput,
            &realPart,
            &imagPart
        )

        // Compute magnitude spectrum.
        for i in 0..<halfN {
            let re = realPart[i]
            let im = imagPart[i]
            magnitudeSnapshot[i] = sqrtf(re * re + im * im)
        }

        // Spectral centroid, flatness, and flux.
        var weightedSum: Float = 0
        var magSum: Float = 0
        var logSum: Float = 0
        var fluxSum: Float = 0
        var magSquaredSum: Float = 0
        let epsilon: Float = 1e-10
        let n = Float(max(halfN - 1, 1))

        for i in 1..<halfN {
            let m = magnitudeSnapshot[i]
            weightedSum += Float(i) * m
            magSum += m
            logSum += logf(m + epsilon)
            magSquaredSum += m * m
        }

        centroid = magSum > epsilon ? (weightedSum / magSum) / Float(halfN) : 0
        let geometricMean = expf(logSum / n)
        let arithmeticMean = magSum / n
        flatness = arithmeticMean > epsilon ? min(geometricMean / arithmeticMean, 1.0) : 0

        // Normalized spectral flux: L2 distance between consecutive magnitude
        // frames, divided by the RMS magnitude of the current frame.
        //   flux = sqrt( Σ (M_t[i] - M_t-1[i])² ) / sqrt( Σ M_t[i]² + ε )
        // This yields ~0 for identical spectra and ~1 for a large spectral
        // change, independent of overall signal level. The first frame seeds
        // M_t-1 from M_t so the initial flux is near zero.
        if !hasPreviousFrame {
            for i in 0..<halfN {
                previousMagnitude[i] = magnitudeSnapshot[i]
            }
            hasPreviousFrame = true
            flux = 0
        } else {
            for i in 1..<halfN {
                let diff = magnitudeSnapshot[i] - previousMagnitude[i]
                fluxSum += diff * diff
                previousMagnitude[i] = magnitudeSnapshot[i]
            }
            let rmsDiff = sqrtf(fluxSum)
            let rmsMag = sqrtf(max(magSquaredSum, epsilon))
            flux = rmsDiff / rmsMag
        }

        applySmoothing(alpha: alpha)

        // Reset the accumulator for the next block.
        accumulatorCount = 0
    }

    private func applySmoothing(alpha: Float) {
        smoothedCentroid = alpha * smoothedCentroid + (1 - alpha) * centroid
        smoothedFlatness = alpha * smoothedFlatness + (1 - alpha) * flatness
        smoothedFlux = alpha * smoothedFlux + (1 - alpha) * flux
    }
}

// MARK: - SpectralAnalyzerNode + DSPNode

extension SpectralAnalyzerNode: GraphNodeDSPProvider, DSPNode {

    var nodeId: UUID { id }

    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // Snapshot the smoothing parameter once; re-reading the COW
        // `parameters` dict inside the loop could allocate on the audio thread.
        let alpha = smoothing

        // Zero the output buffer; this node has no audio output port.
        let bytes = frameCount * MemoryLayout<Float>.stride
        memset(output.left, 0, bytes)
        memset(output.right, 0, bytes)

        guard let inputBuffer = inputs.first else { return }
        let inL = inputBuffer.left

        for i in 0..<frameCount {
            accumulator[accumulatorCount] = inL[i]
            accumulatorCount += 1
            if accumulatorCount >= fftSize {
                analyzeFrame(alpha: alpha)
            }
        }
    }

    func reset() {
        accumulatorCount = 0
        centroid = 0
        flatness = 0
        flux = 0
        smoothedCentroid = 0
        smoothedFlatness = 0
        smoothedFlux = 0
        hasPreviousFrame = false
        for i in 0..<previousMagnitude.count {
            previousMagnitude[i] = 0
        }
    }
}
