import Foundation
import AVFoundation
import Accelerate

// MARK: - Spectral Analyzer Node

/// Converts audio input into spectral feature control signals.
/// Performs FFT analysis and extracts centroid, flatness, and flux.
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
    
    private var realPart: [Float] = []
    private var imagPart: [Float] = []
    private var magnitudeSnapshot: [Float] = []
    private var previousMagnitude: [Float] = []
    private var inputBuffer: [Float] = []
    private var fftSetup: vDSP_DFT_Setup?
    
    private var centroid: Float = 0.0
    private var flatness: Float = 0.0
    private var flux: Float = 0.0
    
    private var smoothedCentroid: Float = 0.0
    private var smoothedFlatness: Float = 0.0
    private var smoothedFlux: Float = 0.0
    
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
    
    // MARK: - Audio Processing
    
    override func audioUnit() -> AVAudioNode? {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 48000,
            channels: 2
        )!
        
        return AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }
            
            let samples = UnsafeMutableBufferPointer<Float>(
                start: buffer.mData?.assumingMemoryBound(to: Float.self),
                count: Int(frameCount)
            )
            
            guard let sampleArray = samples.baseAddress else { return noErr }
            let samplesArray = Array(UnsafeBufferPointer(start: sampleArray, count: Int(frameCount)))
            
            self.analyze(samplesArray)
            
            return noErr
        }
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
        realPart = [Float](repeating: 0, count: n)
        imagPart = [Float](repeating: 0, count: n)
        magnitudeSnapshot = [Float](repeating: 0, count: n / 2)
        previousMagnitude = [Float](repeating: 0, count: n / 2)
        inputBuffer = [Float](repeating: 0, count: n)
        
        fftSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(n),
            vDSP_DFT_Direction.FORWARD
        )
    }
    
    private func analyze(_ samples: [Float]) {
        inputBuffer.append(contentsOf: samples)
        
        while inputBuffer.count >= fftSize {
            let chunk = Array(inputBuffer.prefix(fftSize))
            inputBuffer.removeFirst(fftSize)
            
            performFFT(chunk)
            computeSpectralFeatures()
            applySmoothing()
        }
    }
    
    private func performFFT(_ samples: [Float]) {
        guard let setup = fftSetup else { return }
        
        var inputReal = samples
        var inputImag = [Float](repeating: 0, count: fftSize)
        
        vDSP_DFT_Execute(
            setup,
            &inputReal,
            &inputImag,
            &realPart,
            &imagPart
        )
        
        let halfN = fftSize / 2
        for i in 0..<halfN {
            let re = realPart[i]
            let im = imagPart[i]
            magnitudeSnapshot[i] = sqrtf(re * re + im * im)
        }
    }
    
    private func computeSpectralFeatures() {
        let halfN = fftSize / 2
        guard halfN > 1 else { return }
        
        if previousMagnitude.count != halfN {
            previousMagnitude = [Float](repeating: 0, count: halfN)
        }
        
        var weightedSum: Float = 0
        var magSum: Float = 0
        var logSum: Float = 0
        var fluxSum: Float = 0
        let epsilon: Float = 1e-10
        
        for i in 1..<halfN {
            let m = magnitudeSnapshot[i]
            weightedSum += Float(i) * m
            magSum += m
            logSum += logf(m + epsilon)
            let diff = m - previousMagnitude[i]
            fluxSum += diff * diff
            previousMagnitude[i] = m
        }
        
        let n = Float(halfN - 1)
        centroid = magSum > epsilon
            ? (weightedSum / magSum) / Float(halfN) : 0
        let geometricMean = expf(logSum / n)
        let arithmeticMean = magSum / n
        flatness = arithmeticMean > epsilon
            ? min(geometricMean / arithmeticMean, 1.0) : 0
        flux = sqrtf(fluxSum)
    }
    
    private func applySmoothing() {
        let alpha = smoothing
        smoothedCentroid = alpha * smoothedCentroid + (1 - alpha) * centroid
        smoothedFlatness = alpha * smoothedFlatness + (1 - alpha) * flatness
        smoothedFlux = alpha * smoothedFlux + (1 - alpha) * flux
    }
}
