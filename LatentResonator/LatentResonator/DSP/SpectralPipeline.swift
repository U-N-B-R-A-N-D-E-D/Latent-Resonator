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
/// All buffers are pre-allocated at init. `process(...)` performs zero heap
/// traffic — safe for `DSPNode.render` on the audio thread.
final class SpectralPipeline {

    // MARK: - Configuration

    let fftSize: Int
    let sampleRate: Double
    private let halfN: Int
    private let hopSize: Int
    private let maxBlockSize: Int

    // MARK: - FFT State (pre-allocated)

    private let fftSetup: vDSP_DFT_Setup?
    private let inverseFFTSetup: vDSP_DFT_Setup?
    private var realPart: [Float]
    private var imagPart: [Float]
    private var hannWindow: [Float]

    // MARK: - Working Buffers (pre-allocated, reused every frame)

    private var chunkBuffer: [Float]
    private var overlapAddBuffer: [Float]
    /// Residual tail from the previous `process` call: the IFFT contributions
    /// that extend beyond the current output region into the next hop. Must
    /// persist across calls so the overlap-add reconstruction stays continuous
    /// at block boundaries. Length == `hopSize` is sufficient for 50% overlap.
    /// Pre-allocated at init — no heap traffic on the audio thread.
    private var overlapTail: [Float]

    /// Input history ring buffer. Holds the last `hopSize` samples from the
    /// previous block plus the current block, so STFT frames can span block
    /// boundaries instead of being zero-padded. Pre-allocated at init.
    private var inputRing: [Float]
    /// Number of valid samples currently in `inputRing`. Starts at `hopSize`
    /// because the first `hopSize` slots are pre-filled with zeros to allow a
    /// fully-overlapped first frame (avoids a windowed startup transient).
    private var inputRingCount: Int

    // MARK: - Pipeline State

    private var spectralMemoryReal: [Float]
    private var spectralMemoryImag: [Float]
    private var frozenSpectrumReal: [Float]
    private var frozenSpectrumImag: [Float]
    private var freezeCaptured: Bool = false

    // MARK: - Parameters (smoothed for anti-click)

    private var smoothedSaturation: Float = 0.0
    private var smoothedNoise: Float = 0.0
    private var smoothedMemory: Float = 0.0
    private var smoothedGranularity: Float = 0.0
    private let smoothingFactor: Float = 0.01

    /// Lock-free PRNG for spectral noise/granularity (replaces `Float.random`).
    private var rng = Xoshiro256StarStar()

    // MARK: - Init

    init(fftSize: Int, sampleRate: Double, maxBlockSize: Int = LRConstants.bufferSize) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.maxBlockSize = maxBlockSize
        self.halfN = fftSize / 2
        self.hopSize = fftSize / 2

        // Real-input FFT via packed complex FFT of length N/2: even samples ->
        // real, odd samples -> imag, then complex DFT of length halfN. Buffers
        // realPart/imagPart therefore hold halfN complex samples, so the DFT
        // setup length must match halfN, not fftSize. Using fftSize here caused
        // vDSP_DFT_Execute to write fftSize floats into each halfN buffer — a
        // buffer overflow / SIGSEGV.
        self.fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(halfN), .FORWARD)
        self.inverseFFTSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(halfN), .INVERSE)

        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.spectralMemoryReal = [Float](repeating: 0, count: halfN)
        self.spectralMemoryImag = [Float](repeating: 0, count: halfN)
        self.frozenSpectrumReal = [Float](repeating: 0, count: halfN)
        self.frozenSpectrumImag = [Float](repeating: 0, count: halfN)

        self.hannWindow = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftSize,
            isHalfWindow: false
        )

        self.chunkBuffer = [Float](repeating: 0, count: fftSize)
        self.overlapAddBuffer = [Float](repeating: 0, count: maxBlockSize + fftSize)
        self.overlapTail = [Float](repeating: 0, count: fftSize)
        // Pre-fill the input ring with one hop of zeros so the first frame can
        // start at stream position -hopSize and overlap fully with the first
        // input block. This eliminates the windowed startup transient that
        // would otherwise make the first block non-flat.
        self.inputRing = [Float](repeating: 0, count: fftSize + maxBlockSize)
        self.inputRingCount = hopSize
    }

    deinit {
        // FFT setups are auto-managed by Accelerate
    }

    // MARK: - Main Process Method (RT-safe, in-place)

    /// Process audio through the complete 8-stage spectral pipeline.
    ///
    /// Writes exactly `frameCount` samples into `output`. All scratch memory
    /// is pre-allocated — no heap traffic on the audio thread.
    func process(
        input: UnsafePointer<Float>,
        frameCount: Int,
        output: UnsafeMutablePointer<Float>,
        semanticProfile: UnsafePointer<Float>,
        profileCount: Int,
        saturationAmount: Float,
        noiseAmount: Float,
        memoryCoefficient: Float,
        granularity: Float,
        freezeActive: Bool,
        freezeBlend: Float
    ) {
        guard frameCount > 0, frameCount <= maxBlockSize else {
            for i in 0..<max(0, frameCount) {
                output[i] = 0
            }
            return
        }

        smoothedSaturation += (saturationAmount - smoothedSaturation) * smoothingFactor
        smoothedNoise += (noiseAmount - smoothedNoise) * smoothingFactor
        smoothedMemory += (memoryCoefficient - smoothedMemory) * smoothingFactor
        smoothedGranularity += (granularity - smoothedGranularity) * smoothingFactor

        // Append the new input block to the input history ring. The ring always
        // contains the previous hop (carried from the last block) followed by
        // the current block, so frames can start at the block boundary minus
        // one hop and overlap correctly with the previous block.
        for i in 0..<frameCount {
            inputRing[inputRingCount + i] = input[i]
        }
        inputRingCount += frameCount

        let olaSize = frameCount + fftSize
        // Seed the first `hopSize` slots with the residual tail carried over
        // from the previous block. The first STFT frame starts at ring index 0
        // (stream position S - hopSize) and writes into this region, so the
        // carry-over is added to the next frame's contribution — no click at
        // the block boundary.
        for i in 0..<hopSize {
            overlapAddBuffer[i] = overlapTail[i]
        }
        for i in hopSize..<olaSize {
            overlapAddBuffer[i] = 0
        }

        // Process every full frame in the ring. Because the ring already holds
        // the previous hop, the first frame starts at ring index 0 and overlaps
        // with the previous block; subsequent frames advance by hopSize.
        var pos = 0
        while pos + fftSize <= inputRingCount {
            for i in 0..<fftSize {
                chunkBuffer[i] = inputRing[pos + i]
            }

            processFrameInPlace(
                semanticProfile: semanticProfile,
                profileCount: profileCount,
                saturationAmount: smoothedSaturation,
                noiseAmount: smoothedNoise,
                memoryCoefficient: smoothedMemory,
                granularity: smoothedGranularity,
                freezeActive: freezeActive,
                freezeBlend: freezeBlend
            )

            for i in 0..<fftSize {
                overlapAddBuffer[pos + i] += chunkBuffer[i]
            }

            pos += hopSize
        }

        // The output corresponds to the current input block, which begins one
        // hop into the overlap-add buffer (after the carried-over tail).
        for i in 0..<frameCount {
            output[i] = overlapAddBuffer[hopSize + i]
        }

        // Persist the residual tail for the next call: the IFFT contributions
        // that extend beyond the current output region into the next hop. These
        // are added to the next block's first frame.
        for i in 0..<hopSize {
            overlapTail[i] = overlapAddBuffer[hopSize + frameCount + i]
        }

        // Keep the last hop of the current block in the ring so the next call
        // can start its first frame at the boundary minus one hop.
        for i in 0..<hopSize {
            inputRing[i] = inputRing[frameCount + i]
        }
        inputRingCount = hopSize
    }

    // MARK: - Per-Frame Processing (8 Stages, in-place)

    private func processFrameInPlace(
        semanticProfile: UnsafePointer<Float>,
        profileCount: Int,
        saturationAmount: Float,
        noiseAmount: Float,
        memoryCoefficient: Float,
        granularity: Float,
        freezeActive: Bool,
        freezeBlend: Float
    ) {
        stage1_fft()
        stage2_semanticEQ(profile: semanticProfile, profileCount: profileCount)
        stage3_saturation(amount: saturationAmount)
        stage4_noise(level: noiseAmount)
        stage5_memory(coefficient: memoryCoefficient)
        stage6_granularity(amount: granularity)
        stage7_freeze(active: freezeActive, blend: freezeBlend)
        stage8_ifft()
    }

    // MARK: - Stage 1: FFT Analysis

    // Input-side history is now provided by `inputRing` in `process(...)`,
    // so frames are fully populated with real samples across block boundaries
    // rather than zero-padded.
    private func stage1_fft() {
        vDSP_vmul(chunkBuffer, 1, hannWindow, 1, &chunkBuffer, 1, vDSP_Length(fftSize))

        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                chunkBuffer.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                if let setup = fftSetup {
                    vDSP_DFT_Execute(setup, realBase, imagBase, realBase, imagBase)
                }

                var scale: Float = 0.5
                vDSP_vsmul(realBase, 1, &scale, realBase, 1, vDSP_Length(halfN))
                vDSP_vsmul(imagBase, 1, &scale, imagBase, 1, vDSP_Length(halfN))
            }
        }
    }

    // MARK: - Stage 2: Semantic EQ (4-band)

    private func stage2_semanticEQ(profile: UnsafePointer<Float>, profileCount: Int) {
        guard profileCount >= 4 else { return }

        let nyquist = Float(sampleRate) / 2
        let binFreqWidth = nyquist / Float(halfN)

        for bin in 0..<halfN {
            let freq = Float(bin) * binFreqWidth
            let gain: Float
            if freq < 250 {
                gain = 1.0 + profile[0]
            } else if freq < 1000 {
                gain = 1.0 + profile[1]
            } else if freq < 4000 {
                gain = 1.0 + profile[2]
            } else {
                gain = 1.0 + profile[3]
            }

            realPart[bin] *= gain
            imagPart[bin] *= gain
        }
    }

    // MARK: - Stage 3: Spectral Saturation

    private func stage3_saturation(amount: Float) {
        guard amount > 0 else { return }

        for bin in 0..<halfN {
            let r = realPart[bin]
            let i = imagPart[bin]
            var magnitude = sqrt(r * r + i * i)
            let phase = atan2(i, r)

            if amount < 0.5 {
                let drive = amount * 2
                let saturatedMag = magnitude / (1 + drive * magnitude)
                magnitude = magnitude * (1 - drive) + saturatedMag * drive
            } else {
                let drive = (amount - 0.5) * 2
                let tubeSat = magnitude / (1 + magnitude)
                let hardSat = min(magnitude, 1.0)
                magnitude = tubeSat * (1 - drive) + hardSat * drive
            }

            realPart[bin] = magnitude * cos(phase)
            imagPart[bin] = magnitude * sin(phase)
        }
    }

    // MARK: - Stage 4: Noise Injection

    private func stage4_noise(level: Float) {
        guard level > 0 else { return }

        for bin in 0..<halfN {
            let noiseReal = rng.nextGaussian()
            let noiseImag = rng.nextGaussian()
            realPart[bin] = realPart[bin] * (1 - level) + noiseReal * level
            imagPart[bin] = imagPart[bin] * (1 - level) + noiseImag * level
        }
    }

    // MARK: - Stage 5: Spectral Memory

    private func stage5_memory(coefficient: Float) {
        if coefficient <= 0 {
            for bin in 0..<halfN {
                spectralMemoryReal[bin] = realPart[bin]
                spectralMemoryImag[bin] = imagPart[bin]
            }
            return
        }

        for bin in 0..<halfN {
            realPart[bin] = spectralMemoryReal[bin] * coefficient + realPart[bin] * (1 - coefficient)
            imagPart[bin] = spectralMemoryImag[bin] * coefficient + imagPart[bin] * (1 - coefficient)
            spectralMemoryReal[bin] = realPart[bin]
            spectralMemoryImag[bin] = imagPart[bin]
        }
    }

    // MARK: - Stage 6: Granularity

    private func stage6_granularity(amount: Float) {
        guard amount > 0 else { return }

        for bin in 0..<halfN {
            if rng.nextFloat() < amount {
                realPart[bin] *= 0.01
                imagPart[bin] *= 0.01
            }
        }
    }

    // MARK: - Stage 7: Spectral Freeze

    private func stage7_freeze(active: Bool, blend: Float) {
        if active {
            if !freezeCaptured {
                for bin in 0..<halfN {
                    frozenSpectrumReal[bin] = realPart[bin]
                    frozenSpectrumImag[bin] = imagPart[bin]
                }
                freezeCaptured = true
            }

            for bin in 0..<halfN {
                realPart[bin] = realPart[bin] * (1 - blend) + frozenSpectrumReal[bin] * blend
                imagPart[bin] = imagPart[bin] * (1 - blend) + frozenSpectrumImag[bin] * blend
            }
        } else {
            freezeCaptured = false
        }
    }

    // MARK: - Stage 8: IFFT Synthesis

    private func stage8_ifft() {
        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }

                if let setup = inverseFFTSetup {
                    vDSP_DFT_Execute(setup, realBase, imagBase, realBase, imagBase)
                }

                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)
                chunkBuffer.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ztoc(&splitComplex, 1, complexPtr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }

        var scale: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(chunkBuffer, 1, &scale, &chunkBuffer, 1, vDSP_Length(fftSize))

        // P0 fix (Round 2 audit, James) — this used to re-apply `hannWindow`
        // here on the way out. stage1_fft already windows the analysis
        // frame, so the round trip was squaring the window (Hann * Hann).
        // A single Hann window satisfies COLA at 50% hop (hopSize ==
        // fftSize/2, see init): w(n) + w(n + N/2) == 1 for all n. Hann²
        // does NOT — its OLA sum ripples between 0.5 and 1.0 (6.02 dB),
        // i.e. amplitude modulation at (sampleRate / fftSize * 2) Hz baked
        // into every signal, including full bypass (saturation/noise/
        // memory/granularity all at 0). Removing the synthesis window
        // restores single-Hann COLA — analysis-only windowing is already
        // constant-overlap-add correct. Do NOT re-add a window here
        // without re-deriving the COLA identity for whatever hop/window
        // combination is in use at the time.
    }

    // MARK: - Public Reset

    /// Clear all state (buffers, memory, freeze, input ring).
    func reset() {
        for i in 0..<overlapAddBuffer.count { overlapAddBuffer[i] = 0 }
        for i in 0..<overlapTail.count { overlapTail[i] = 0 }
        for i in 0..<inputRing.count { inputRing[i] = 0 }
        inputRingCount = hopSize
        for i in 0..<halfN {
            spectralMemoryReal[i] = 0
            spectralMemoryImag[i] = 0
            frozenSpectrumReal[i] = 0
            frozenSpectrumImag[i] = 0
        }
        freezeCaptured = false
        smoothedSaturation = 0
        smoothedNoise = 0
        smoothedMemory = 0
        smoothedGranularity = 0
    }

    // MARK: - Offline / Test Convenience

    /// Array-friendly overload for offline processing and tests.
    ///
    /// Bridges `[Float]` ↔ `UnsafePointer` so callers (tests, offline render,
    /// non-RT bounce paths) can use the same 8-stage pipeline without manually
    /// managing scratch buffers. The RT `process(input:frameCount:output:...)`
    /// overload remains the canonical path on the audio thread.
    ///
    /// - Returns: Processed samples, length == `input.count`.
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
        let frameCount = input.count
        var output = [Float](repeating: 0, count: frameCount)
        guard frameCount > 0 else { return output }

        let profileCount = max(4, semanticProfile.count)
        var profile = semanticProfile
        while profile.count < profileCount { profile.append(0) }

        input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                profile.withUnsafeBufferPointer { profBuf in
                    guard let inBase = inBuf.baseAddress,
                          let outBase = outBuf.baseAddress,
                          let profBase = profBuf.baseAddress else { return }
                    self.process(
                        input: inBase,
                        frameCount: frameCount,
                        output: outBase,
                        semanticProfile: profBase,
                        profileCount: profileCount,
                        saturationAmount: saturationAmount,
                        noiseAmount: noiseAmount,
                        memoryCoefficient: memoryCoefficient,
                        granularity: granularity,
                        freezeActive: freezeActive,
                        freezeBlend: freezeBlend
                    )
                }
            }
        }
        return output
    }
}
