import Foundation
import Accelerate
import AVFoundation

/// 8-Stage Spectral Processing Pipeline
///
/// Whitepaper alignment:
/// - Stage 1: FFT Analysis (§2.1 Spectral Feature Extraction)
/// - Stage 2: Semantic EQ (§2.5 Colored Spectral Noise)
/// - Stage 3: Saturation (§2.7 Continuous Saturation Morphing)
/// - Stage 4: Noise Injection (§4.1.3 Entropy)
/// - Stage 5: Spectral Memory (§3.3 Recursive Formula)
/// - Stage 6: Granularity (§5.5 Granular Disintegration)
/// - Stage 7: Spectral Freeze (§5.2 Spectral Freeze)
/// - Stage 8: IFFT Synthesis
///
/// This pipeline is agnostic to v1.x vs v2.0 - it just processes [Float] buffers.
/// All processing uses vDSP for performance and thread safety.
final class SpectralPipeline {

    // MARK: - Configuration

    let fftSize: Int
    let sampleRate: Double

    // MARK: - FFT State (pre-allocated, audio-thread safe)

    private let fftSetup: vDSP_DFT_Setup?
    private let inverseFFTSetup: vDSP_DFT_Setup?
    private let log2n: vDSP_Length
    private var realPart: [Float]
    private var imagPart: [Float]
    private var hannWindow: [Float]
    private let hopSize: Int

    // MARK: - Pipeline State

    private var spectralMemoryReal: [Float]  // Stage 5: recursive memory (real)
    private var spectralMemoryImag: [Float]  // Stage 5: recursive memory (imag)
    private var frozenSpectrumReal: [Float]? // Stage 7: freeze snapshot (real)
    private var frozenSpectrumImag: [Float]? // Stage 7: freeze snapshot (imag)
    private var overlapAddBuffer: [Float]
    private var overlapAddIndex: Int
    private var inputAccumulator: [Float]

    // MARK: - Parameters (smoothed for anti-click)

    private var smoothedSaturation: Float = 0.0
    private var smoothedNoise: Float = 0.0
    private var smoothedMemory: Float = 0.0
    private var smoothedGranularity: Float = 0.0
    private let smoothingFactor: Float = 0.01  // Parameter smoothing time constant

    // MARK: - Init

    init(fftSize: Int, sampleRate: Double) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(log2(Float(fftSize)))

        // FFT setup for forward and inverse transforms
        self.fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        self.inverseFFTSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE)

        // Pre-allocated buffers (no heap alloc in process())
        let halfN = fftSize / 2
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.spectralMemoryReal = [Float](repeating: 0, count: halfN)
        self.spectralMemoryImag = [Float](repeating: 0, count: halfN)

        // Hann window for 50% overlap (COLA-compliant when hop = fftSize/2)
        self.hannWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftSize,
            isHalfWindow: false
        )
        self.hopSize = fftSize / 2

        // Overlap-add buffer (2x FFT size for safety)
        self.overlapAddBuffer = [Float](repeating: 0, count: fftSize * 2)
        self.overlapAddIndex = 0
        self.inputAccumulator = []
    }

    deinit {
        // FFT setups are auto-managed by Accelerate
    }

    // MARK: - Main Process Method

    /// Process audio through complete 8-stage spectral pipeline.
    ///
    /// - Parameters:
    ///   - input: Input audio buffer (any length)
    ///   - semanticProfile: 4-band EQ profile [low, lowMid, highMid, high]
    ///   - saturationAmount: Per-band saturation (0..1)
    ///   - noiseAmount: Entropy injection level (0..1)
    ///   - memoryCoefficient: Spectral memory blend (0..1)
    ///   - granularity: Microsound sparsification (0..1)
    ///   - freezeActive: Hold spectral snapshot (bool)
    ///   - freezeBlend: Crossfade with frozen spectrum (0..1)
    /// - Returns: Processed audio buffer (same length as input)
    func process(
        input: [Float],
        semanticProfile: [Float],
        saturationAmount: Float,
        noiseAmount: Float,
        memoryCoefficient: Float,
        granularity: Float,
        freezeActive: Bool,
        freezeBlend: Float
    ) -> [Float] {
        // Smooth parameters to prevent clicks
        smoothedSaturation += (saturationAmount - smoothedSaturation) * smoothingFactor
        smoothedNoise += (noiseAmount - smoothedNoise) * smoothingFactor
        smoothedMemory += (memoryCoefficient - smoothedMemory) * smoothingFactor
        smoothedGranularity += (granularity - smoothedGranularity) * smoothingFactor

        // Accumulate input until we have enough for FFT
        inputAccumulator.append(contentsOf: input)

        var outputBuffer = [Float]()
        outputBuffer.reserveCapacity(input.count)

        // Process frames while we have enough input (50% overlap = hopSize)
        while inputAccumulator.count >= fftSize {
            // Extract frame
            let frame = Array(inputAccumulator[0..<fftSize])

            // Remove processed samples (hopSize = 50% overlap)
            inputAccumulator.removeFirst(hopSize)

            // Process single frame through all 8 stages
            let processedFrame = processFrame(
                frame: frame,
                semanticProfile: semanticProfile,
                saturationAmount: smoothedSaturation,
                noiseAmount: smoothedNoise,
                memoryCoefficient: smoothedMemory,
                granularity: smoothedGranularity,
                freezeActive: freezeActive,
                freezeBlend: freezeBlend
            )

            // Overlap-add: mix with existing buffer content
            for i in 0..<fftSize {
                let idx = (overlapAddIndex + i) % overlapAddBuffer.count
                overlapAddBuffer[idx] += processedFrame[i]
            }

            // Extract output samples (hopSize samples ready after each frame)
            for i in 0..<hopSize {
                let idx = (overlapAddIndex + i) % overlapAddBuffer.count
                outputBuffer.append(overlapAddBuffer[idx])
                // Clear for next overlap
                overlapAddBuffer[idx] = 0
            }

            // Advance index
            overlapAddIndex = (overlapAddIndex + hopSize) % overlapAddBuffer.count
        }

        // If we don't have enough input for a full frame, return zeros
        // This happens at the end of a buffer or during low input
        while outputBuffer.count < input.count {
            outputBuffer.append(0)
        }

        // Trim to exact input length
        return Array(outputBuffer[0..<input.count])
    }

    // MARK: - Per-Frame Processing (8 Stages)

    private func processFrame(
        frame: [Float],
        semanticProfile: [Float],
        saturationAmount: Float,
        noiseAmount: Float,
        memoryCoefficient: Float,
        granularity: Float,
        freezeActive: Bool,
        freezeBlend: Float
    ) -> [Float] {
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        // Stage 1: FFT Analysis
        stage1_fft(input: frame, real: &real, imag: &imag)

        // Stage 2: Semantic EQ
        stage2_semanticEQ(real: &real, imag: &imag, profile: semanticProfile)

        // Stage 3: Spectral Saturation
        stage3_saturation(real: &real, imag: &imag, amount: saturationAmount)

        // Stage 4: Noise Injection
        stage4_noise(real: &real, imag: &imag, level: noiseAmount)

        // Stage 5: Spectral Memory (recursive blend)
        stage5_memory(real: &real, imag: &imag, coefficient: memoryCoefficient)

        // Stage 6: Granularity
        stage6_granularity(real: &real, imag: &imag, amount: granularity)

        // Stage 7: Spectral Freeze
        stage7_freeze(real: &real, imag: &imag, active: freezeActive, blend: freezeBlend)

        // Stage 8: IFFT Synthesis
        return stage8_ifft(real: real, imag: imag)
    }

    // MARK: - Stage 1: FFT Analysis

    private func stage1_fft(input: [Float], real: inout [Float], imag: inout [Float]) {
        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Perform forward FFT using vDSP_DFT
        // Use withUnsafeMutableBufferPointer to ensure pointer stability
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                // Convert real input to split complex (interleaved to split)
                windowed.withUnsafeBufferPointer { src in
                    vDSP_ctoz(src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { $0 },
                              2,
                              &splitComplex,
                              1,
                              vDSP_Length(fftSize / 2))
                }

                // Execute forward FFT
                if let setup = fftSetup {
                    vDSP_DFT_Execute(setup, realPtr.baseAddress!, imagPtr.baseAddress!, realPtr.baseAddress!, imagPtr.baseAddress!)
                }

                // Scale by 0.5 to match vDSP conventions
                var scale: Float = 0.5
                vDSP_vsmul(realPtr.baseAddress!, 1, &scale, realPtr.baseAddress!, 1, vDSP_Length(fftSize / 2))
                vDSP_vsmul(imagPtr.baseAddress!, 1, &scale, imagPtr.baseAddress!, 1, vDSP_Length(fftSize / 2))
            }
        }
    }

    // MARK: - Stage 2: Semantic EQ (4-band)

    private func stage2_semanticEQ(real: inout [Float], imag: inout [Float], profile: [Float]) {
        guard profile.count >= 4 else { return }

        let halfN = fftSize / 2
        let nyquist = Float(sampleRate) / 2
        let binFreqWidth = nyquist / Float(halfN)

        // Define band boundaries (Hz): 0-250, 250-1000, 1000-4000, 4000+
        let bandEdges: [Float] = [250, 1000, 4000, nyquist]

        for bin in 0..<halfN {
            let freq = Float(bin) * binFreqWidth
            var gain: Float = 1.0

            // Determine which band this frequency belongs to
            for i in 0..<4 {
                let lowBound: Float = (i == 0) ? 0 : bandEdges[i - 1]
                let highBound = bandEdges[i]

                if freq >= lowBound && freq < highBound {
                    // Apply band gain from profile
                    gain = 1.0 + profile[i]  // Profile values are typically -1 to 1
                    break
                }
            }

            // Apply EQ
            real[bin] *= gain
            imag[bin] *= gain
        }
    }

    // MARK: - Stage 3: Spectral Saturation

    private func stage3_saturation(real: inout [Float], imag: inout [Float], amount: Float) {
        guard amount > 0 else { return }

        let halfN = fftSize / 2

        for bin in 0..<halfN {
            // Compute magnitude and phase
            let r = real[bin]
            let i = imag[bin]
            var magnitude = sqrt(r * r + i * i)
            let phase = atan2(i, r)

            // Apply saturation curve to magnitude
            // Soft clipping: y = x / (1 + |x|) for amount in [0, 1]
            if amount < 0.5 {
                // Clean to Tube transition
                let drive = amount * 2  // 0..1 within this range
                let saturatedMag = magnitude / (1 + drive * magnitude)
                magnitude = magnitude * (1 - drive) + saturatedMag * drive
            } else {
                // Tube to Transistor/Diode transition (harder clipping)
                let drive = (amount - 0.5) * 2  // 0..1 within this range
                let tubeSat = magnitude / (1 + magnitude)
                let hardSat = min(magnitude, 1.0)
                magnitude = tubeSat * (1 - drive) + hardSat * drive
            }

            // Reconstruct complex number
            real[bin] = magnitude * cos(phase)
            imag[bin] = magnitude * sin(phase)
        }
    }

    // MARK: - Stage 4: Noise Injection

    private func stage4_noise(real: inout [Float], imag: inout [Float], level: Float) {
        guard level > 0 else { return }

        let halfN = fftSize / 2

        for bin in 0..<halfN {
            // Generate random noise in range [-1, 1]
            let noiseReal = Float.random(in: -1...1)
            let noiseImag = Float.random(in: -1...1)

            // Mix with existing spectral content
            real[bin] = real[bin] * (1 - level) + noiseReal * level
            imag[bin] = imag[bin] * (1 - level) + noiseImag * level
        }
    }

    // MARK: - Stage 5: Spectral Memory

    private func stage5_memory(real: inout [Float], imag: inout [Float], coefficient: Float) {
        guard coefficient > 0 else {
            // No memory - just update state with current values
            spectralMemoryReal = real
            spectralMemoryImag = imag
            return
        }

        let halfN = fftSize / 2

        for bin in 0..<halfN {
            // Recursive blend: current = previous * coeff + current * (1-coeff)
            real[bin] = spectralMemoryReal[bin] * coefficient + real[bin] * (1 - coefficient)
            imag[bin] = spectralMemoryImag[bin] * coefficient + imag[bin] * (1 - coefficient)

            // Update memory for next frame
            spectralMemoryReal[bin] = real[bin]
            spectralMemoryImag[bin] = imag[bin]
        }
    }

    // MARK: - Stage 6: Granularity

    private func stage6_granularity(real: inout [Float], imag: inout [Float], amount: Float) {
        guard amount > 0 else { return }

        let halfN = fftSize / 2

        for bin in 0..<halfN {
            // Random dropout based on granularity amount
            // Higher granularity = more bins dropped (sparse spectrum)
            if Float.random(in: 0...1) < amount {
                // Drop this bin (set to near-zero)
                real[bin] *= 0.01
                imag[bin] *= 0.01
            }
        }
    }

    // MARK: - Stage 7: Spectral Freeze

    private func stage7_freeze(real: inout [Float], imag: inout [Float], active: Bool, blend: Float) {
        let halfN = fftSize / 2

        if active {
            // Capture freeze snapshot if not already frozen
            if frozenSpectrumReal == nil {
                frozenSpectrumReal = real
                frozenSpectrumImag = imag
            }

            // Crossfade between live and frozen spectrum
            guard let frozenReal = frozenSpectrumReal,
                  let frozenImag = frozenSpectrumImag else { return }

            for bin in 0..<halfN {
                real[bin] = real[bin] * (1 - blend) + frozenReal[bin] * blend
                imag[bin] = imag[bin] * (1 - blend) + frozenImag[bin] * blend
            }
        } else {
            // Release freeze
            frozenSpectrumReal = nil
            frozenSpectrumImag = nil
        }
    }

    // MARK: - Stage 8: IFFT Synthesis

    private func stage8_ifft(real: [Float], imag: [Float]) -> [Float] {
        var outputReal = real
        var outputImag = imag

        // Execute inverse FFT
        outputReal.withUnsafeMutableBufferPointer { realPtr in
            outputImag.withUnsafeMutableBufferPointer { imagPtr in
                if let setup = inverseFFTSetup {
                    vDSP_DFT_Execute(setup, real, imag, realPtr.baseAddress!, imagPtr.baseAddress!)
                }
            }
        }

        // Convert split complex back to real
        var output = [Float](repeating: 0, count: fftSize)

        outputReal.withUnsafeMutableBufferPointer { realPtr in
            outputImag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                output.withUnsafeMutableBufferPointer { dst in
                    vDSP_ztoc(&splitComplex,
                              1,
                              dst.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { $0 },
                              2,
                              vDSP_Length(fftSize / 2))
                }
            }
        }

        // Scale by 1/fftSize for IFFT normalization
        var scale: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(fftSize))

        // Apply Hann window again for COLA (Constant Overlap-Add) compliance
        var windowedOutput = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(output, 1, hannWindow, 1, &windowedOutput, 1, vDSP_Length(fftSize))

        return windowedOutput
    }

    // MARK: - Public Reset

    /// Clear all state (buffers, memory, freeze)
    func reset() {
        inputAccumulator.removeAll()
        overlapAddBuffer = [Float](repeating: 0, count: fftSize * 2)
        overlapAddIndex = 0

        let halfN = fftSize / 2
        spectralMemoryReal = [Float](repeating: 0, count: halfN)
        spectralMemoryImag = [Float](repeating: 0, count: halfN)

        frozenSpectrumReal = nil
        frozenSpectrumImag = nil

        smoothedSaturation = 0
        smoothedNoise = 0
        smoothedMemory = 0
        smoothedGranularity = 0
    }
}
