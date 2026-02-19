import Foundation
import Accelerate

// MARK: - Non-Linear Spectral Processor
// Implements the "Semantic Filter" described in the white paper §6.1.
//
// Transfer function is concept-based, not frequency-based:
//   Input: "Click"
//   Transfer Function: "Make it sound like Ferrofluid"
//   Output: "Liquid Click"
//
// Processing chain (13 stages):
//   [Audio] -> Hann -> FFT -> SemanticEQ -> SpectralNoise ->
//   SpectralMemory -> SpectralGranularity -> SpectralFreeze -> IFFT ->
//   LadderFilter -> CombFilter -> TunableResonator -> BitCrush ->
//   Waveshaper -> [Audio]
//
// When Core ML models are unavailable, this processor IS the
// "Black Box Resonator," creating recursive degradation entirely
// in the spectral domain. The spectralMemory array is the DSP
// analogue of the latentState vector in CoreMLInference.

final class SpectralProcessor {

    // MARK: - FFT Configuration

    private var fftSize: Int
    private var halfN: Int
    private var fftLog2n: vDSP_Length
    private var fftSetup: FFTSetup

    /// Split complex buffers reused across calls (no allocation in hot path).
    private var realPart: [Float]
    private var imagPart: [Float]

    // MARK: - Spectral Memory (Recursive Drift State)

    /// Persistent spectral magnitude -- the DSP analogue of latentState.
    /// Captures "resonant frequencies" of the feedback loop over time.
    /// Frequencies that persist across iterations get reinforced,
    /// just as Lucier's room amplified its resonant frequencies.
    private var spectralMemory: [Float]

    // MARK: - Comb Filter State

    /// Circular delay line for parallel comb filters.
    /// Prime-number delay spacing -> inharmonic metallic partials.
    private var combDelayLine: [Float]
    private var combWritePos: Int = 0
    private let combDelayLength: Int

    // MARK: - Tunable Resonator State (§5.4 Metallic Sheen as Instrument)

    /// Separate comb delay line for the tunable pitched resonator.
    /// Delay length is derived from MIDI note -> frequency -> samples.
    private var resonatorDelayLine: [Float]
    private var resonatorWritePos: Int = 0
    private let resonatorMaxDelay: Int

    // MARK: - Spectral Freeze State (§5.2 Saturation)

    /// Captured spectral snapshot for freeze effect.
    /// When freeze is active, the current spectrum is blended
    /// with this frozen snapshot, sustaining a spectral moment.
    private var frozenSpectrum: [Float]?

    // MARK: - Semantic Profile

    /// 4-band spectral gain derived from prompt keywords.
    /// [low, lowMid, highMid, high]
    private(set) var spectralProfile: [Float] = [1.0, 1.0, 1.0, 1.0]

    /// Magnitude snapshot of the most recent FFT frame (fftSize/2 bins).
    /// Updated each STFT hop; safe to read from the UI thread at a throttled rate.
    private(set) var magnitudeSnapshot: [Float] = []

    // MARK: - Spectral Features (Real-Time Analysis)

    /// Normalized spectral centroid [0..1] where 0 = DC, 1 = Nyquist.
    /// High values indicate bright/metallic timbre; low = warm/bassy.
    private(set) var spectralCentroid: Float = 0.0

    /// Spectral flatness [0..1] where 0 = tonal/harmonic, 1 = noise-like.
    /// Measures how far the spectrum is from white noise.
    private(set) var spectralFlatness: Float = 0.0

    /// Spectral flux: frame-to-frame magnitude change [0..inf).
    /// Measures the rate of timbral evolution.
    private(set) var spectralFlux: Float = 0.0

    /// Previous frame's magnitude for flux computation (pre-allocated).
    private var previousMagnitude: [Float] = []

    // MARK: - Precomputed Window

    private var hannWindow: [Float]

    // MARK: - Pre-allocated Audio Thread Buffers (Phase 1: No Heap on Hot Path)
    //
    // These replace the `var chunk = [Float](...)` and `var output = [Float](...)`
    // allocations that were happening inside `process()` on every audio callback.
    // Audio threads must never allocate heap memory (causes priority inversion).

    private var chunkBuffer: [Float]
    private var outputBuffer: [Float]

    /// Overlap-add accumulation buffer for COLA-compliant STFT reconstruction.
    /// Sized to sampleCount + fftSize to handle the trailing overlap region.
    private var overlapAddBuffer: [Float] = []

    /// Hop size for 50% overlap STFT (COLA-compliant with Hann window).
    private var hopSize: Int

    // MARK: - Moog-style Ladder Filter State (Phase 3: Analog Character)
    //
    // 4-pole (24dB/oct) ladder filter using the Huovilainen improved
    // model -- standard in digital analog emulation. The single most
    // impactful addition for analog character.
    //
    // State variables for the 4 cascaded 1-pole sections:
    private var ladderStage: (Float, Float, Float, Float) = (0, 0, 0, 0)

    // MARK: - Parameter Smoothing (Max/MSP slide~ equivalent)
    //
    // 1-pole lowpass on DSP parameters prevents clicks/zips when knobs
    // change abruptly. Coefficient 0.15 ~= 50ms ramp at 512-sample buffers.

    private static let smoothCoeff: Float = 0.15
    private var smoothedCfg: Float = LRConstants.cfgScaleRange.lowerBound
    private var smoothedCrush: Float = 0.0
    private var smoothedResPitch: Float = 0.0
    private var smoothedFeedback: Float = 0.0
    private var smoothedResDecay: Float = 0.85
    private var smoothedFilterCutoff: Float = LRConstants.filterCutoffDefault
    private var smoothedFilterResonance: Float = LRConstants.filterResonanceDefault

    /// Apply 1-pole lowpass: `out += coeff * (target - out)`
    @inline(__always)
    private func smoothParam(_ current: inout Float, toward target: Float) {
        current += Self.smoothCoeff * (target - current)
    }

    // MARK: - Initialization

    /// Sample rate used for delay-length calculations.
    private let sampleRate: Double

    init(sampleRate: Double = LRConstants.sampleRate) {
        self.sampleRate = sampleRate
        fftSize = LRConstants.fftSize
        halfN = fftSize / 2
        fftLog2n = vDSP_Length(LRConstants.fftLog2n)

        guard let setup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2)) else {
            fatalError(">> SpectralProcessor: Failed to create FFT setup")
        }
        fftSetup = setup

        realPart = [Float](repeating: 0, count: halfN)
        imagPart = [Float](repeating: 0, count: halfN)
        spectralMemory = [Float](repeating: 0, count: halfN)

        // Comb filter delay: enough room for all staggered taps
        combDelayLength = LRConstants.combBaseDelay * LRConstants.combFilterTaps * 2
        combDelayLine = [Float](repeating: 0, count: combDelayLength)

        // Tunable resonator: max delay = sampleRate / minFreq
        // LRConstants.resonatorPitchRange.lowerBound is 20 Hz
        resonatorMaxDelay = Int(sampleRate / Double(LRConstants.resonatorPitchRange.lowerBound)) + 1
        resonatorDelayLine = [Float](repeating: 0, count: resonatorMaxDelay)

        // Precompute Hann window for spectral-leakage prevention
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hannWindow = window

        // Hop size: 50% overlap for COLA-compliant Hann window reconstruction
        hopSize = fftSize / 2

        // Pre-allocate working buffers (Phase 1: avoid heap on audio thread)
        chunkBuffer = [Float](repeating: 0, count: fftSize)
        outputBuffer = [Float](repeating: 0, count: LRConstants.bufferSize)
        overlapAddBuffer = [Float](repeating: 0, count: LRConstants.bufferSize + fftSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Reconfigure FFT size at preset-load time (NOT during audio processing).
    /// Must be called from the main thread before processing begins.
    func reconfigure(fftSize newSize: Int) {
        guard LRConstants.availableFFTSizes.contains(newSize), newSize != fftSize else { return }
        vDSP_destroy_fftsetup(fftSetup)
        fftSize = newSize
        halfN = newSize / 2
        let log2 = Int(log2f(Float(newSize)))
        fftLog2n = vDSP_Length(log2)
        guard let setup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2)) else {
            fatalError(">> SpectralProcessor: Failed to create FFT setup for size \(newSize)")
        }
        fftSetup = setup
        realPart = [Float](repeating: 0, count: halfN)
        imagPart = [Float](repeating: 0, count: halfN)
        spectralMemory = [Float](repeating: 0, count: halfN)
        magnitudeSnapshot = [Float](repeating: 0, count: halfN)
        previousMagnitude = [Float](repeating: 0, count: halfN)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hannWindow = window
        hopSize = fftSize / 2
        chunkBuffer = [Float](repeating: 0, count: fftSize)
    }

    // MARK: - Prompt -> Spectral Profile

    /// Parse a semantic prompt and derive the 4-band spectral profile.
    /// Matching keywords from LRConstants.semanticProfiles are averaged.
    ///
    /// Example: "metallic decay, ferrofluid texture"
    ///   -> matches: metallic, decay, ferrofluid, texture
    ///   -> averaged gains across 4 bands
    func updateProfile(from prompt: String) {
        var accum: [Float] = [0, 0, 0, 0]
        var matches = 0

        let lowered = prompt.lowercased()
        for (keyword, gains) in LRConstants.semanticProfiles {
            if lowered.contains(keyword) {
                for i in 0..<4 { accum[i] += gains[i] }
                matches += 1
            }
        }

        if matches > 0 {
            for i in 0..<4 { accum[i] /= Float(matches) }
            spectralProfile = accum
        } else {
            spectralProfile = [1.0, 1.0, 1.0, 1.0]
        }
    }

    // MARK: - Main Processing

    /// Process audio through the complete Non-Linear Spectral Processor chain.
    ///
    /// Implements the recursive formula from §3.3 entirely in the spectral domain:
    ///   S_{i+1} = IFFT( SemanticFilter( FFT(S_i) + ε*N(0,1) ) ⊕ Memory )
    ///
    /// Extended chain (Analog Personality Engine):
    ///   [Audio] -> Hann -> FFT -> SemanticEQ -> SpectralNoise -> SpectralMemory ->
    ///   SpectralGranularity -> SpectralFreeze -> IFFT -> LadderFilter ->
    ///   CombFilter -> TunableResonator -> BitCrush -> Waveshaper -> [Audio]
    ///
    /// - Parameters:
    ///   - samples: Input audio samples (mono)
    ///   - guidanceScale: CFG value -- controls distortion/saturation intensity
    ///   - entropyLevel: Normalized [0..1] -- spectral noise injection
    ///   - granularity: Normalized [0..1] -- spectral sparsification
    ///   - feedbackAmount: Spectral memory blend [0..1] -- recursive drift depth
    ///   - freezeActive: When true, captures/sustains a spectral moment (§5.2)
    ///   - bitCrushDepth: Normalized [0..1] -- 0 = off, 1 = maximum quantization
    ///   - resonatorPitch: Frequency in Hz -- 0 = off, >0 = tuned comb resonator
    ///   - resonatorDecay: Resonator feedback decay
    ///   - filterCutoff: Ladder filter cutoff frequency in Hz
    ///   - filterResonance: Ladder filter resonance [0..0.95]
    ///   - filterMode: LP/HP/BP filter type
    ///   - saturationMode: Waveshaper circuit model
    ///   - saturationMorph: Crossfade [0..1] toward the next saturation mode
    /// - Returns: Processed audio samples (written into pre-allocated buffer)
    func process(
        samples: [Float],
        guidanceScale: Float,
        entropyLevel: Float,
        granularity: Float,
        feedbackAmount: Float,
        freezeActive: Bool = false,
        bitCrushDepth: Float = 0.0,
        resonatorPitch: Float = 0.0,
        resonatorDecay: Float = 0.85,
        filterCutoff: Float = LRConstants.filterCutoffDefault,
        filterResonance: Float = LRConstants.filterResonanceDefault,
        filterMode: FilterMode = .lowpass,
        saturationMode: SaturationMode = .clean,
        saturationMorph: Float = 0.0
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }

        // Smooth all DSP parameters (slide~ equivalent -- prevents clicks)
        smoothParam(&smoothedCfg, toward: guidanceScale)
        smoothParam(&smoothedCrush, toward: bitCrushDepth)
        smoothParam(&smoothedResPitch, toward: resonatorPitch)
        smoothParam(&smoothedFeedback, toward: feedbackAmount)
        smoothParam(&smoothedResDecay, toward: resonatorDecay)
        smoothParam(&smoothedFilterCutoff, toward: filterCutoff)
        smoothParam(&smoothedFilterResonance, toward: filterResonance)

        let sCfg = smoothedCfg
        let sCrush = smoothedCrush
        let sResPitch = smoothedResPitch
        let sFeedback = smoothedFeedback
        let sResDecay = smoothedResDecay
        let sFilterCut = smoothedFilterCutoff
        let sFilterRes = smoothedFilterResonance

        // Ensure overlap-add buffer is large enough (reuse pre-allocated)
        let sampleCount = samples.count
        let olaSize = sampleCount + fftSize
        if overlapAddBuffer.count < olaSize {
            overlapAddBuffer = [Float](repeating: 0, count: olaSize)
        }
        // Zero the overlap-add accumulation buffer
        for i in 0..<olaSize { overlapAddBuffer[i] = 0 }

        var pos = 0

        // 50% overlap STFT: hop by hopSize (fftSize/2), accumulate into OLA buffer.
        // Hann window at 50% hop satisfies COLA (constant-overlap-add) constraint,
        // so the sum of overlapping analysis windows = 1.0 everywhere.
        while pos < sampleCount {
            let remaining = sampleCount - pos
            let chunkSize = min(fftSize, remaining)

            // Prepare FFT-sized chunk using pre-allocated buffer (no heap alloc)
            for i in 0..<fftSize { chunkBuffer[i] = 0 }
            for i in 0..<chunkSize {
                chunkBuffer[i] = samples[pos + i]
            }

            // -- Step 1: Hann window (prevents spectral leakage) --
            vDSP_vmul(chunkBuffer, 1, hannWindow, 1, &chunkBuffer, 1, vDSP_Length(fftSize))

            // -- Step 2: Pack into split complex + forward FFT --
            packForFFT(chunkBuffer)
            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(
                        realp: realBuf.baseAddress!,
                        imagp: imagBuf.baseAddress!
                    )
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2n,
                                  FFTDirection(kFFTDirection_Forward))
                }
            }

            // -- Step 3: Semantic spectral profile (prompt-derived 4-band EQ) --
            applySemanticProfile()

            // -- Step 3b: Per-band spectral saturation (prompt-shaped harmonic enrichment) --
            if sCfg > 5.0 {
                applySpectralSaturation(guidanceScale: sCfg)
            }

            // -- Step 4: Spectral noise injection (entropy -> frequency domain) --
            if entropyLevel > 0.001 {
                injectSpectralNoise(level: entropyLevel)
            }

            // -- Step 5: Spectral memory blend (recursive drift) --
            blendSpectralMemory(feedbackAmount: sFeedback)

            // -- Step 6: Spectral granularity (microsound sparsification) --
            if granularity > 0.01 {
                applySpectralGranularity(granularity)
            }

            // -- Step 7: Spectral freeze -- sustain a spectral moment (§5.2) --
            applySpectralFreeze(active: freezeActive)

            // -- Step 7b: Snapshot magnitudes for UI visualization --
            let halfN = fftSize / 2
            if magnitudeSnapshot.count != halfN {
                magnitudeSnapshot = [Float](repeating: 0, count: halfN)
            }
            for i in 0..<halfN {
                magnitudeSnapshot[i] = sqrtf(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
            }

            // -- Step 7c: Spectral feature extraction --
            computeSpectralFeatures(halfN: halfN)

            // -- Step 8: Inverse FFT + unpack --
            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(
                        realp: realBuf.baseAddress!,
                        imagp: imagBuf.baseAddress!
                    )
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, fftLog2n,
                                  FFTDirection(kFFTDirection_Inverse))
                }
            }
            unpackFromFFT(&chunkBuffer)

            // Normalize (vDSP FFT requires 1/(2N) scaling for round-trip)
            var scale = 1.0 / Float(fftSize * 2)
            vDSP_vsmul(chunkBuffer, 1, &scale, &chunkBuffer, 1, vDSP_Length(fftSize))

            // Overlap-add: accumulate into OLA buffer (COLA reconstruction)
            for i in 0..<fftSize {
                if pos + i < olaSize {
                    overlapAddBuffer[pos + i] += chunkBuffer[i]
                }
            }

            pos += hopSize
        }

        // Copy the reconstructed signal to output
        if outputBuffer.count < sampleCount {
            outputBuffer = [Float](repeating: 0, count: sampleCount)
        }
        for i in 0..<sampleCount {
            outputBuffer[i] = overlapAddBuffer[i]
        }

        // -- TIME-DOMAIN PROCESSING (runs on full reconstructed signal) --
        // These IIR filters MUST run after overlap-add, not per-chunk,
        // to avoid doubled/interfering responses in the overlap region.

        // -- Step 9: Ladder filter -- analog character (Phase 3) --
        applyLadderFilter(&outputBuffer, count: sampleCount,
                          cutoff: sFilterCut, resonance: sFilterRes,
                          mode: filterMode)

        // -- Step 10: Comb filter -- metallic resonance (§5.4 artifact) --
        applyCombFilter(&outputBuffer, count: sampleCount, guidanceScale: sCfg)

        // -- Step 11: Tunable resonator -- pitched metallic sheen (§5.4) --
        if sResPitch > 0.0 {
            applyTunableResonator(&outputBuffer, count: sampleCount,
                                  pitchHz: sResPitch, decay: sResDecay)
        }

        // -- Step 12: Bit crusher -- quantization noise (§5.4 granular dust) --
        if sCrush > 0.001 {
            applyBitCrush(&outputBuffer, count: sampleCount, depth: sCrush)
        }

        // -- Step 13: Guidance-driven waveshaper (Phase 4: Analog Circuit) --
        let gain = powf(max(sCfg, 0.1) / 10.0, 1.5)
        applyWaveshaper(&outputBuffer, count: sampleCount,
                        gain: gain, mode: saturationMode,
                        morphPosition: saturationMorph)

        return Array(outputBuffer[0..<sampleCount])
    }

    // MARK: - FFT Packing / Unpacking

    /// Pack N real samples into split complex format for vDSP_fft_zrip.
    /// realp[i] = data[2*i], imagp[i] = data[2*i+1]
    @inline(__always)
    private func packForFFT(_ data: [Float]) {
        for i in 0..<halfN {
            realPart[i] = data[2 * i]
            imagPart[i] = data[2 * i + 1]
        }
    }

    /// Unpack split complex back to interleaved real samples.
    @inline(__always)
    private func unpackFromFFT(_ data: inout [Float]) {
        for i in 0..<halfN {
            data[2 * i] = realPart[i]
            data[2 * i + 1] = imagPart[i]
        }
    }

    // MARK: - Spectral Manipulation

    /// Apply 4-band semantic spectral profile.
    /// Divides the spectrum into 4 equal bands and applies gain
    /// derived from prompt keywords -- the "Semantic Filter" (§6.1).
    private func applySemanticProfile() {
        let bandSize = halfN / 4

        for band in 0..<4 {
            let gain = spectralProfile[band]
            let start = band * bandSize
            let end = (band == 3) ? halfN : (band + 1) * bandSize

            for i in start..<end {
                realPart[i] *= gain
                imagPart[i] *= gain
            }
        }
    }

    /// Inject colored Gaussian noise in the frequency domain.
    /// Creates spectral perturbation analogous to diffusion noise,
    /// acting as "nucleation sites" for new timbral structures (§4.1.3).
    ///
    /// Noise amplitude per bin is shaped by the semantic spectralProfile:
    /// "metallic" prompts inject more high-frequency noise, "warm" prompts
    /// inject more low-frequency noise. A single entropy knob produces
    /// semantically different results depending on the active prompt.
    ///
    /// Scaling: level [0..1] maps to noiseAmp via quadratic curve.
    /// At 0.25 entropy -> subtle texture. At 0.5 -> clear noise character.
    /// At 1.0 -> heavy spectral noise. Quadratic curve gives more
    /// resolution in the low range where subtle textures live.
    private func injectSpectralNoise(level: Float) {
        let noiseAmp = level * level * 0.5 + level * 0.1  // Quadratic: 0->0, 0.5->0.175, 1.0->0.6
        let bandSize = max(halfN / 4, 1)
        for i in 1..<halfN {   // Skip DC bin
            let band = min(i / bandSize, 3)
            let coloredAmp = noiseAmp * spectralProfile[band]
            realPart[i] += SignalGenerator.boxMullerNoise() * coloredAmp
            imagPart[i] += SignalGenerator.boxMullerNoise() * coloredAmp
        }
    }

    /// Apply per-band waveshaping in the frequency domain. Each spectral band
    /// is saturated proportionally to its semantic profile weight, creating
    /// prompt-dependent harmonic enrichment: "metallic" prompts saturate highs,
    /// "warm" prompts saturate lows. No heap allocations.
    private func applySpectralSaturation(guidanceScale: Float) {
        let gain = powf(max(guidanceScale, 0.1) / 10.0, 1.5)
        let bandSize = max(halfN / 4, 1)
        for band in 0..<4 {
            let bandGain = gain * spectralProfile[band]
            let start = band * bandSize
            let end = (band == 3) ? halfN : (band + 1) * bandSize
            for i in start..<end {
                let mag = sqrtf(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
                guard mag > 1e-10 else { continue }
                let saturated = tanhf(mag * bandGain) / mag
                realPart[i] *= saturated
                imagPart[i] *= saturated
            }
        }
    }

    /// Compute spectral centroid, flatness, and flux from the current magnitudeSnapshot.
    /// All arithmetic uses pre-allocated buffers; no heap allocations.
    private func computeSpectralFeatures(halfN: Int) {
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
        spectralCentroid = magSum > epsilon
            ? (weightedSum / magSum) / Float(halfN) : 0
        let geometricMean = expf(logSum / n)
        let arithmeticMean = magSum / n
        spectralFlatness = arithmeticMean > epsilon
            ? min(geometricMean / arithmeticMean, 1.0) : 0
        spectralFlux = sqrtf(fluxSum)
    }

    /// Blend current spectrum with persistent spectral memory.
    ///
    /// This is the DSP analogue of latent-space recursive feedback:
    /// frequencies that persist across iterations get reinforced,
    /// just as Lucier's room amplified its resonant frequencies (§1.2).
    ///
    /// Memory blend:   mem[k] = α*mem[k] + (1-α)*|X[k]|
    /// Emphasis:        X[k] *= 1 + feedback * (mem[k]/|X[k]| - 1)
    private func blendSpectralMemory(feedbackAmount: Float) {
        guard feedbackAmount > 0.001 else { return }

        let alpha = LRConstants.spectralMemoryCoeff * feedbackAmount

        for i in 1..<halfN {   // Skip DC
            let mag = sqrt(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])

            // Update running spectral average
            spectralMemory[i] = alpha * spectralMemory[i] + (1.0 - alpha) * mag

            // Apply emphasis: amplify persistent frequencies
            if mag > 0.0001 {
                let emphasis = 1.0 + feedbackAmount * (spectralMemory[i] / mag - 1.0)
                let clamped = min(max(emphasis, 0.1), 4.0) // prevent runaway
                realPart[i] *= clamped
                imagPart[i] *= clamped
            }
        }
    }

    /// Spectral sparsification -- the frequency-domain expression of granularity.
    /// At high granularity, random spectral bins are zeroed out,
    /// creating the "granular dust" artifact (§5.4 taxonomy).
    private func applySpectralGranularity(_ granularity: Float) {
        let zeroProb = granularity * 0.7  // Max 70% of bins zeroed
        for i in 1..<halfN {
            if Float.random(in: 0...1) < zeroProb {
                realPart[i] = 0
                imagPart[i] = 0
            }
        }
    }

    // MARK: - Comb Filter

    /// Parallel comb filters with prime-number delay spacing.
    /// Creates the "Metallic Sheen" artifact (§5.4): high-frequency
    /// ringing and inharmonic resonance characteristic of high-CFG diffusion.
    private func applyCombFilter(
        _ data: inout [Float],
        count: Int,
        guidanceScale: Float
    ) {
        let feedback = LRConstants.combFeedback * min(guidanceScale / 20.0, 1.0)
        guard feedback > 0.001 else { return }

        for i in 0..<count {
            var combSum: Float = 0

            // Sum from multiple delay taps (prime spacing for inharmonicity)
            for tap in 0..<LRConstants.combFilterTaps {
                let delay = LRConstants.combBaseDelay * (tap + 1)
                if delay < combDelayLength {
                    let readPos = (combWritePos - delay + combDelayLength) % combDelayLength
                    combSum += combDelayLine[readPos]
                }
            }
            combSum /= Float(LRConstants.combFilterTaps)

            // Blend: input + filtered comb output
            let mixed = data[i] + combSum * feedback

            // Write to delay line (sanitize to prevent NaN propagation)
            combDelayLine[combWritePos] = mixed.isNaN || mixed.isInfinite ? 0 : mixed
            combWritePos = (combWritePos + 1) % combDelayLength

            data[i] = mixed.isNaN || mixed.isInfinite ? 0 : mixed
        }
    }

    // MARK: - Spectral Freeze (§5.2 -- Sustaining a Spectral Moment)

    /// Capture and sustain a spectral snapshot.
    ///
    /// When activated, the current spectral magnitude is stored.
    /// On subsequent frames the processor crossfades between the live
    /// spectrum and the frozen snapshot, creating a sustained drone
    /// that slowly decays -- the spectral equivalent of holding a piano
    /// sustain pedal while the "room resonance" persists.
    ///
    /// When deactivated, the snapshot is released and
    /// the live spectrum resumes immediately.
    private func applySpectralFreeze(active: Bool) {
        guard active else {
            // Release frozen state when toggled off
            frozenSpectrum = nil
            return
        }

        // Capture snapshot on first active frame
        if frozenSpectrum == nil {
            var magnitudes = [Float](repeating: 0, count: halfN)
            for i in 0..<halfN {
                magnitudes[i] = sqrt(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
            }
            frozenSpectrum = magnitudes
        }

        guard let frozen = frozenSpectrum else { return }

        // Blend: mostly frozen, small amount of live for movement
        let freezeMix: Float = 0.92  // 92% frozen, 8% live -> subtle drift
        for i in 1..<halfN {  // Skip DC
            let liveMag = sqrt(realPart[i] * realPart[i] + imagPart[i] * imagPart[i])
            guard liveMag > 1e-10 else { continue }

            let targetMag = freezeMix * frozen[i] + (1.0 - freezeMix) * liveMag
            let ratio = targetMag / liveMag

            realPart[i] *= ratio
            imagPart[i] *= ratio
        }
    }

    // MARK: - Bit Crusher (§5.4 -- Granular Dust Artifact)

    /// Quantize sample amplitude, reducing bit depth.
    ///
    /// This creates the "Granular Dust" artifact from the taxonomy (§5.4):
    /// crackling, geiger-counter textures that arise from aggressive
    /// quantization. At maximum depth the signal is reduced to ~2-bit,
    /// producing pure square-wave-like artifacts.
    ///
    /// Exponential mapping gives more resolution in the "crunchy" middle
    /// zone (4-8 bit) where the most musical crush textures live, while
    /// still reaching extreme 2-bit at maximum depth.
    ///
    /// - Parameters:
    ///   - data: Audio buffer (modified in place)
    ///   - count: Number of valid samples
    ///   - depth: Normalized [0..1] -- 0 = off (no quantization), 1 = maximum crush
    private func applyBitCrush(_ data: inout [Float], count: Int, depth: Float) {
        // Exponential mapping: depth [0..1] -> bits [16 .. 2]
        // depth^1.5 curve concentrates slider travel in the musical 4-8 bit zone.
        //   depth 0.0 -> 16 bits (transparent)
        //   depth 0.3 -> ~13.7 bits (subtle warmth)
        //   depth 0.5 -> ~11.1 bits (lo-fi character)
        //   depth 0.7 -> ~7.8 bits (crunchy)
        //   depth 1.0 -> 2 bits (extreme)
        let maxBits: Float = 16.0
        let minBits: Float = 2.0
        let shaped = powf(depth, 1.5)
        let bits = maxBits - shaped * (maxBits - minBits)
        let levels = powf(2.0, bits)

        for i in 0..<count {
            // Quantize: round to nearest level
            data[i] = roundf(data[i] * levels) / levels
        }
    }

    // MARK: - Tunable Resonator (§5.4 -- Metallic Sheen as Instrument)

    /// A pitched comb filter that transforms the metallic sheen artifact
    /// into a playable element. The delay length is set by frequency,
    /// creating a resonant peak at that pitch and its harmonics.
    ///
    /// This is distinct from the existing comb filter (which uses
    /// fixed prime-number spacing for inharmonic resonance). Here
    /// we create a single tuned feedback delay for pitched resonance.
    ///
    /// - Parameters:
    ///   - data: Audio buffer (modified in place)
    ///   - count: Number of valid samples
    ///   - pitchHz: Resonant frequency in Hz
    private func applyTunableResonator(
        _ data: inout [Float],
        count: Int,
        pitchHz: Float,
        decay: Float = 0.85
    ) {
        guard pitchHz >= LRConstants.resonatorPitchRange.lowerBound else { return }

        let delaySamples = Int(sampleRate / Double(pitchHz))
        guard delaySamples > 0, delaySamples < resonatorMaxDelay else { return }

        // Decay [0..0.99] maps directly to comb filter feedback.
        // Low decay = short ring, high decay = long pitched ringing.
        let resonatorFeedback: Float = min(decay, 0.99)

        // Wet/dry blend scales with decay: more decay = more resonator presence.
        let wet = 0.3 + decay * 0.5        // [0.3 .. 0.8]
        let dry = 1.0 - wet * 0.6          // keeps dry audible

        for i in 0..<count {
            let readPos = (resonatorWritePos - delaySamples + resonatorMaxDelay) % resonatorMaxDelay
            let delayed = resonatorDelayLine[readPos]

            // Mix: excitation + delayed feedback
            let mixed = data[i] + delayed * resonatorFeedback

            // Write into delay line (sanitize to prevent NaN propagation)
            let safeMixed = mixed.isNaN || mixed.isInfinite ? 0 : mixed
            resonatorDelayLine[resonatorWritePos] = safeMixed
            resonatorWritePos = (resonatorWritePos + 1) % resonatorMaxDelay

            // Output: blend of dry and resonated
            data[i] = data[i] * dry + safeMixed * wet
        }
    }

    // MARK: - Moog-style Ladder Filter (Topology-Preserving Transform)
    //
    // 4-pole (24dB/oct) ladder filter using the TPT (Topology-Preserving
    // Transform) structure from Zavalishin, "The Art of VA Filter Design."
    // Each 1-pole stage uses the resolved form: v = G*(x - s), ensuring
    // unconditional stability for all cutoff frequencies (G in (0,1)).
    //
    // The cutoff frequency is THE most expressive parameter in analog
    // synthesis. A single cutoff sweep produces more musical interest
    // than all spectral knobs combined.
    //
    // Three modes:
    //   LP -- classic warm subtractive sound (Minimoog, Juno-60)
    //   HP -- thin, sharp, removes body (tension)
    //   BP -- vocal, resonant, wah-like (filter sweeps)

    private func applyLadderFilter(
        _ data: inout [Float],
        count: Int,
        cutoff: Float,
        resonance: Float,
        mode: FilterMode
    ) {
        // Skip if filter is wide open and no resonance
        guard cutoff < 19900.0 || resonance > 0.01 else { return }

        let sr = Float(sampleRate)
        // Bilinear transform: warp analog cutoff to digital domain
        let g = tanf(.pi * min(cutoff, sr * 0.49) / sr)
        // Trapezoidal integrator coefficient -- must be g/(1+g) for stability
        // (Zavalishin, "The Art of VA Filter Design", ch. 4)
        let gComp = g / (1.0 + g)
        // Feedback amount (resonance -> self-oscillation near 0.95)
        let k = 4.0 * resonance

        var s0 = ladderStage.0
        var s1 = ladderStage.1
        var s2 = ladderStage.2
        var s3 = ladderStage.3

        for i in 0..<count {
            let input = data[i]

            // Feedback: subtract resonant output from input
            let feedback = input - k * s3

            // 4 cascaded 1-pole TPT lowpass sections (Zavalishin, ch. 4)
            // Each stage: v = G*(x - s), y = v + s, s_new = y + v
            // The (x - s) term provides the negative state feedback that
            // makes this a LOWPASS filter rather than an unbounded integrator.
            let v0 = gComp * (feedback - s0)
            let t0 = v0 + s0
            s0 = t0 + v0

            let v1 = gComp * (t0 - s1)
            let t1 = v1 + s1
            s1 = t1 + v1

            let v2 = gComp * (t1 - s2)
            let t2 = v2 + s2
            s2 = t2 + v2

            let v3 = gComp * (t2 - s3)
            let t3 = v3 + s3
            s3 = t3 + v3

            // Mode selection
            switch mode {
            case .lowpass:
                data[i] = t3                      // 4-pole LP output
            case .highpass:
                data[i] = input - t3              // HP = input - LP
            case .bandpass:
                data[i] = t1 - t3                 // BP = 2-pole - 4-pole
            }
        }

        // Snap-to-zero: flush denormals that can accumulate into NaN over time.
        // Standard DSP practice (equivalent to JUCE's snapToZero).
        @inline(__always) func snap(_ v: Float) -> Float {
            abs(v) < 1e-15 ? 0 : v
        }
        s0 = snap(s0); s1 = snap(s1); s2 = snap(s2); s3 = snap(s3)

        // NaN/Inf guard: if any stage has diverged, reset all state to zero.
        // This prevents a single poisoned sample from causing permanent silence.
        if s0.isNaN || s0.isInfinite || s1.isNaN || s1.isInfinite
            || s2.isNaN || s2.isInfinite || s3.isNaN || s3.isInfinite {
            s0 = 0; s1 = 0; s2 = 0; s3 = 0
        }

        ladderStage = (s0, s1, s2, s3)
    }

    // MARK: - Analog Waveshaper (Phase 4: Tube/Transistor/Diode)
    //
    // Selectable waveshaping that models actual analog circuits.
    // The CFG guidance scale controls gain INTO the waveshaper -- this
    // is correct and stays. The waveshaper TYPE changes the harmonic
    // character of that distortion.
    //
    // - CLEAN:      current tanh with unity gain. Transparent.
    // - TUBE:       asymmetric soft clip: x/(1+|x|) + even harmonics.
    //               Warm, musical. 1950s-60s character (Buchla, early Moog).
    // - TRANSISTOR: harder clip with odd harmonics: tanh(x*2.5)*0.8.
    //               More aggressive, gritty. 1970s-80s (TB-303, SH-101).
    // - DIODE:      hard asymmetric clip: positive clipped, negative passed.
    //               Buzzy, broken character. Raw circuit sound.

    /// Per-sample waveshaping for a single mode (no allocation).
    @inline(__always)
    private func shapeSample(_ x: Float, gain: Float, mode: SaturationMode) -> Float {
        switch mode {
        case .clean:
            return tanhf(x * gain)
        case .tube:
            let g = x * gain
            let soft = g / (1.0 + fabsf(g))
            return soft + 0.1 * soft * fabsf(soft)
        case .transistor:
            return tanhf(x * gain * 2.5) * 0.8
        case .diode:
            let g = x * gain
            return g > 0.0 ? min(g, 0.6) : max(g * 1.2, -1.0)
        }
    }

    private func applyWaveshaper(
        _ data: inout [Float],
        count: Int,
        gain: Float,
        mode: SaturationMode,
        morphPosition: Float = 0.0
    ) {
        if morphPosition < 0.001 {
            for i in 0..<count {
                data[i] = shapeSample(data[i], gain: gain, mode: mode)
            }
        } else {
            let allModes = SaturationMode.allCases
            guard let currentIdx = allModes.firstIndex(of: mode) else { return }
            let nextIdx = (currentIdx + 1) % allModes.count
            let nextMode = allModes[nextIdx]
            let t = morphPosition
            for i in 0..<count {
                let a = shapeSample(data[i], gain: gain, mode: mode)
                let b = shapeSample(data[i], gain: gain, mode: nextMode)
                data[i] = a + (b - a) * t
            }
        }
    }

    // MARK: - State Management

    /// Reset all persistent state. Call when restarting the feedback loop.
    func reset() {
        spectralMemory = [Float](repeating: 0, count: halfN)
        combDelayLine = [Float](repeating: 0, count: combDelayLength)
        combWritePos = 0
        resonatorDelayLine = [Float](repeating: 0, count: resonatorMaxDelay)
        resonatorWritePos = 0
        frozenSpectrum = nil
        ladderStage = (0, 0, 0, 0)
        for i in 0..<overlapAddBuffer.count { overlapAddBuffer[i] = 0 }
    }

}
