# DSP Implementation Patterns — Spectral & Filter Design

**Trigger phrases:** "DSP", "filter", "FFT", "spectral", "frequency domain", "ladder filter", "comb filter", "resonator", "waveshaper", "saturation", "EQ", "frequency", "magnitude", "phase"

**Purpose:** Provide battle-tested DSP patterns for implementing audio effects and spectral processing in Latent Resonator. Focuses on Accelerate vDSP, analog filter models, and FFT-domain techniques.

---

## WHEN TO LOAD THIS SKILL

- User wants to add a new DSP effect or filter
- User mentions "FFT", "spectral processing", "frequency domain"
- User is modifying a node in `Graph/Nodes/FilterEffectNodes.swift`, `SpectralNodes.swift`, or `SpectralProcessor.swift`
- User wants to implement filters (lowpass, highpass, bandpass, comb, etc.)
- User asks about analog modeling (Moog, TB-303, waveshaping)
- User needs to understand existing DSP code

---

## NEW EFFECTS ARE DSPNODES, NOT ADDITIONS TO SpectralProcessor

**This is the one thing that changed since this file was first written: new effects do not get bolted onto `SpectralProcessor.process()` anymore.** `SpectralProcessor.swift` still exists and still runs the algorithms below, but it's now internal, private state used by exactly one node (`SpectralChainNode`, mid-migration, out of scope for unrelated changes). Every *new* effect is its own `final class` in the matching `Graph/Nodes/*.swift` file (filters/effects → `FilterEffectNodes.swift`), conforming to `DSPNode` + `GraphNodeDSPProvider`, registered in `NodeFactory.createNode(...)` in `NodeGraph.swift`.

The math on this page (ladder filter, comb filter, waveshaping, bit crusher, spectral feature extraction, ...) is still exactly right — it's the per-sample DSP itself that doesn't change. What changes is the *wrapper*: instead of a `process(samples: inout [Float])` method on a monolithic processor, each algorithm below becomes the body of one node's `render(inputs:output:frameCount:sampleRate:controls:)`. Load the `v2-node-graph` skill for the exact node skeleton (copy `DelayLineNode` in `FilterEffectNodes.swift`) and the `audio-thread-safety` skill for the real-time constraints `render` must honor.

```swift
// The shape every new effect node takes — see v2-node-graph for the full template
extension MyNewEffectNode: GraphNodeDSPProvider, DSPNode {
    var nodeId: UUID { id }
    func dspNode() -> DSPNode? { self }
    func render(inputs: UnsafeBufferPointer<AudioBuffer>, output: AudioBuffer,
                frameCount: Int, sampleRate: Double, controls: [String: Float]) {
        guard let inBuf = inputs.first else { /* zero output */ return }
        // <-- the per-sample algorithm from this page goes here, operating on
        //     output.left / output.right (pre-allocated stereo state, no allocation)
    }
    func reset() { /* clear delay lines / filter state */ }
}
```

---

## FFT-BASED SPECTRAL PROCESSING

### The STFT Pipeline (Short-Time Fourier Transform)

**From SpectralProcessor.swift — complete pattern:**

```swift
final class SpectralProcessor {
    
    // MARK: - FFT Configuration
    
    private var fftSize: Int
    private var halfN: Int
    private var hopSize: Int       // fftSize / 2 for 50% overlap
    private var fftLog2n: vDSP_Length
    private var fftSetup: FFTSetup?
    
    // MARK: - Pre-Allocated Buffers
    
    private var chunkBuffer: [Float]
    private var outputBuffer: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    private var phases: [Float]
    private var hannWindow: [Float]
    private var overlapAddBuffer: [Float]
    
    // MARK: - Init
    
    init(fftSize: Int, sampleRate: Double) {
        self.fftSize = fftSize
        self.halfN = fftSize / 2
        self.hopSize = fftSize / 2
        self.fftLog2n = vDSP_Length(log2(Float(fftSize)))
        
        // Create FFT setup (reused forever)
        self.fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        
        // Pre-allocate all working memory
        self.chunkBuffer = [Float](repeating: 0, count: fftSize)
        self.outputBuffer = [Float](repeating: 0, count: fftSize)
        self.realPart = [Float](repeating: 0, count: halfN)
        self.imagPart = [Float](repeating: 0, count: halfN)
        self.magnitudes = [Float](repeating: 0, count: halfN)
        self.phases = [Float](repeating: 0, count: halfN)
        self.overlapAddBuffer = [Float](repeating: 0, count: fftSize * 2)
        self.hannWindow = [Float](repeating: 0, count: fftSize)
        
        // Precompute Hann window
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }
    
    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }
    
    // MARK: - Process
    
    func process(samples: inout [Float]) {
        var readPos = 0
        overlapAddBuffer.replaceSubrange(0..<overlapAddBuffer.count, with: repeatElement(0, count: overlapAddBuffer.count))
        
        while readPos + fftSize <= samples.count {
            // 1. Extract chunk
            for i in 0..<fftSize {
                chunkBuffer[i] = samples[readPos + i]
            }
            
            // 2. Apply window
            vDSP_vmul(chunkBuffer, 1, hannWindow, 1, &chunkBuffer, 1, vDSP_Length(fftSize))
            
            // 3. Forward FFT
            forwardFFT(input: chunkBuffer, real: &realPart, imag: &imagPart)
            
            // 4. Compute magnitude and phase
            cartesianToPolar(real: realPart, imag: imagPart, mag: &magnitudes, phase: &phases)
            
            // 5. Process in frequency domain
            processSpectrum(magnitudes: &magnitudes)
            
            // 6. Reconstruct complex from magnitude (phase preserved)
            polarToCartesian(mag: magnitudes, phase: phases, real: &realPart, imag: &imagPart)
            
            // 7. Inverse FFT
            inverseFFT(real: realPart, imag: imagPart, output: &outputBuffer)
            
            // 8. Overlap-add
            for i in 0..<fftSize {
                overlapAddBuffer[readPos + i] += outputBuffer[i]
            }
            
            readPos += hopSize
        }
        
        // Copy overlap-add result back to input
        for i in 0..<samples.count {
            samples[i] = overlapAddBuffer[i]
        }
    }
    
    // MARK: - FFT Helpers
    
    @inline(__always)
    private func forwardFFT(input: [Float], real: inout [Float], imag: inout [Float]) {
        // Copy input into real part (interleaved as re,im,re,im,...)
        for i in 0..<halfN {
            real[i] = input[2 * i]
            imag[i] = input[2 * i + 1]
        }
        
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_fft_zrip(
                    fftSetup,
                    &splitComplex,
                    1,
                    fftLog2n,
                    FFTDirection(FFT_FORWARD)
                )
            }
        }
    }
    
    @inline(__always)
    private func inverseFFT(real: [Float], imag: [Float], output: inout [Float]) {
        var realCopy = real
        var imagCopy = imag
        
        realCopy.withUnsafeMutableBufferPointer { realPtr in
            imagCopy.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_fft_zrip(
                    fftSetup,
                    &splitComplex,
                    1,
                    fftLog2n,
                    FFTDirection(FFT_INVERSE)
                )
            }
        }
        
        // Scale by 1/(2*N) for correct IFFT normalization
        var scale = Float(1.0) / Float(2 * fftSize)
        vDSP_vsmul(realCopy, 1, &scale, &realCopy, 1, vDSP_Length(halfN))
        vDSP_vsmul(imagCopy, 1, &scale, &imagCopy, 1, vDSP_Length(halfN))
        
        // Deinterleave back to time domain
        for i in 0..<halfN {
            output[2 * i] = realCopy[i]
            output[2 * i + 1] = imagCopy[i]
        }
    }
    
    @inline(__always)
    private func cartesianToPolar(
        real: [Float],
        imag: [Float],
        mag: inout [Float],
        phase: inout [Float]
    ) {
        real.withUnsafeBufferPointer { realPtr in
            imag.withUnsafeBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: realPtr.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: imagPtr.baseAddress!)
                )
                
                // Magnitude
                vDSP_zvabs(&splitComplex, 1, &mag, 1, vDSP_Length(halfN))
                
                // Phase
                vDSP_zvphas(&splitComplex, 1, &phase, 1, vDSP_Length(halfN))
            }
        }
    }
    
    @inline(__always)
    private func polarToCartesian(
        mag: [Float],
        phase: [Float],
        real: inout [Float],
        imag: inout [Float]
    ) {
        for i in 0..<halfN {
            real[i] = mag[i] * cos(phase[i])
            imag[i] = mag[i] * sin(phase[i])
        }
    }
}
```

### Why 50% Overlap?

**COLA (Constant Overlap-Add) requirement:**

With Hann window: `w(n) + w(n + N/2) = 1`

This ensures amplitude remains constant at hop boundaries (no modulation artifacts).

---

## MOOG-STYLE LADDER FILTER (4-POLE)

### The Huovilainen Improved Model

**From SpectralProcessor.swift — industry-standard analog emulation:**

```swift
// MARK: - Moog Ladder Filter State

/// 4-pole cascaded 1-pole sections
private var ladderStage: (Float, Float, Float, Float) = (0, 0, 0, 0)

/// Processes one sample through 4-pole ladder with resonance feedback.
@inline(__always)
private func ladderFilterSample(
    _ input: Float,
    cutoff: Float,
    resonance: Float,
    mode: FilterMode
) -> Float {
    // Compute filter coefficient from cutoff frequency
    // fc_norm = cutoff / sampleRate
    // g = tan(π * fc_norm) ≈ π * fc_norm for low frequencies
    let fcNorm = cutoff / Float(sampleRate)
    let g = min(0.99, .pi * fcNorm)  // Clamp to Nyquist
    
    // Resonance feedback gain (0..4 for self-oscillation at Q=4)
    let k = resonance * 4.0
    
    // Compute input with resonance feedback from stage 4
    let inputWithFeedback = input - k * ladderStage.3
    
    // 4 cascaded 1-pole lowpass stages
    let s1 = ladderStage.0 + g * (inputWithFeedback - ladderStage.0)
    let s2 = ladderStage.1 + g * (s1 - ladderStage.1)
    let s3 = ladderStage.2 + g * (s2 - ladderStage.2)
    let s4 = ladderStage.3 + g * (s3 - ladderStage.3)
    
    // Update state
    ladderStage = (s1, s2, s3, s4)
    
    // Mode selection
    switch mode {
    case .lowpass:
        return s4  // Output from final stage (24dB/oct LP)
    case .highpass:
        return input - s4  // Subtract LP from input (24dB/oct HP)
    case .bandpass:
        return s2 - s4  // Difference between stages (12dB/oct BP)
    }
}

enum FilterMode: String, Codable {
    case lowpass = "LP"
    case highpass = "HP"
    case bandpass = "BP"
}
```

**Why this model?**
- Huovilainen's improved topology (2006) is numerically stable
- Self-oscillation at resonance = 1.0
- Matches analog Moog response (confirmed via frequency sweep tests)
- Single sample recursion → perfect for per-sample processing

---

## COMB FILTER (METALLIC RESONANCE)

### Prime-Number Delay Spacing

**From SpectralProcessor.swift — creates inharmonic partials:**

```swift
// MARK: - Comb Filter State

private var combDelayLine: [Float]
private var combWritePos: Int = 0
private let combBaseDelay: Int  // Prime number (137, 149, 163, etc.)

init(...) {
    self.combBaseDelay = 137  // Prime → inharmonic
    self.combDelayLine = [Float](repeating: 0, count: combBaseDelay * 5)
}

/// Parallel comb with 5 taps at prime-number spacings.
@inline(__always)
private func combFilterSample(_ input: Float, feedback: Float) -> Float {
    let primes = [137, 149, 163, 179, 191]  // First 5 primes near base
    
    var output: Float = 0.0
    
    for prime in primes {
        let delayIndex = (combWritePos - prime + combDelayLine.count) % combDelayLine.count
        let delayed = combDelayLine[delayIndex]
        output += delayed
    }
    
    output *= 0.2  // 1/5 (equal mix of 5 taps)
    
    // Write to delay line with feedback
    combDelayLine[combWritePos] = input + output * feedback
    combWritePos = (combWritePos + 1) % combDelayLine.count
    
    return output
}
```

**Why prime numbers?**
- Avoids harmonic reinforcement (no common factors)
- Creates inharmonic metallic partials
- Signature "Latent Resonator" sound (§5.4 in whitepaper)

---

## TUNABLE RESONATOR (PITCHED COMB)

### MIDI Note → Delay Length

**From SpectralProcessor.swift:**

```swift
// MARK: - Tunable Resonator State

private var resonatorDelayLine: [Float]
private var resonatorWritePos: Int = 0
private let resonatorMaxDelay: Int

init(...) {
    // Max delay for lowest note (MIDI 24 = C1 ≈ 32.7 Hz)
    self.resonatorMaxDelay = Int(sampleRate / 32.7) + 1
    self.resonatorDelayLine = [Float](repeating: 0, count: resonatorMaxDelay)
}

/// Pitched resonator: delay length derived from MIDI note.
@inline(__always)
private func resonatorSample(
    _ input: Float,
    note: Float,      // MIDI note number (0-127)
    decay: Float      // Feedback (0-0.99)
) -> Float {
    // MIDI to frequency: f = 440 * 2^((n - 69) / 12)
    let freq = 440.0 * pow(2.0, (note - 69.0) / 12.0)
    
    // Frequency to delay samples: delay = sampleRate / freq
    let delaySamples = Int(sampleRate / Double(freq))
    let clampedDelay = min(delaySamples, resonatorMaxDelay - 1)
    
    // Read delayed sample
    let readIndex = (resonatorWritePos - clampedDelay + resonatorMaxDelay) % resonatorMaxDelay
    let delayed = resonatorDelayLine[readIndex]
    
    // Write with feedback
    resonatorDelayLine[resonatorWritePos] = input + delayed * decay
    resonatorWritePos = (resonatorWritePos + 1) % resonatorMaxDelay
    
    return delayed
}
```

**Result:** Pitched resonator that rings at specified MIDI note.

---

## WAVESHAPING (ANALOG SATURATION)

### Continuous Morph Between Transfer Functions

**Four circuit models: clean → tube → transistor → diode**

```swift
/// Applies analog saturation with continuous morphing.
/// morph [0..1] crossfades between adjacent modes.
@inline(__always)
private func waveshape(_ input: Float, morph: Float) -> Float {
    let absIn = abs(input)
    let sign = input < 0 ? -1.0 : 1.0
    
    // Four transfer functions
    let clean = input  // Linear passthrough
    
    let tube = {
        // Soft saturation (exponential curve)
        if absIn < 1.0 {
            return input * (1.0 + 0.3 * absIn)
        } else {
            return sign * (1.3 - exp(1.0 - absIn))
        }
    }()
    
    let transistor = {
        // Hard clipping with soft knee
        if absIn < 0.5 {
            return input
        } else if absIn < 1.0 {
            let x = (absIn - 0.5) * 2.0
            return sign * (0.5 + 0.5 * tanh(x * 3.0))
        } else {
            return sign
        }
    }()
    
    let diode = {
        // Asymmetric clipping (diode threshold ≈ 0.7V)
        let threshold: Float = 0.7
        if input > threshold {
            return threshold + (input - threshold) * 0.1
        } else if input < -threshold {
            return -threshold + (input + threshold) * 0.3
        } else {
            return input
        }
    }()
    
    // Continuous morph [0..3]
    let m = morph * 3.0
    
    if m < 1.0 {
        // Clean → Tube
        return clean + m * (tube - clean)
    } else if m < 2.0 {
        // Tube → Transistor
        let t = m - 1.0
        return tube + t * (transistor - tube)
    } else {
        // Transistor → Diode
        let t = m - 2.0
        return transistor + t * (diode - transistor)
    }
}
```

**Apply to full buffer:**
```swift
func processWaveshaping(samples: inout [Float], morph: Float) {
    for i in 0..<samples.count {
        samples[i] = waveshape(samples[i], morph: morph)
    }
}
```

**Why morph?**
- Eliminates clicks when switching modes
- Enables expressive timbral sweeps
- Maps to WARMTH macro (continuous control)

---

## BIT CRUSHER (QUANTIZATION DISTORTION)

### Reduce Bit Depth in Real-Time

```swift
/// Reduces bit depth to create digital artifacts.
/// depth [2..16]: lower = more distortion, 16 = clean
@inline(__always)
private func bitCrush(_ input: Float, depth: Float) -> Float {
    guard depth < 16.0 else { return input }  // No crushing at 16-bit
    
    let levels = pow(2.0, depth)  // 2^depth quantization levels
    let step = 2.0 / levels       // Step size in [-1..1] range
    
    // Quantize
    let quantized = round(input / step) * step
    
    return quantized
}
```

**Apply to buffer:**
```swift
func processBitCrush(samples: inout [Float], depth: Float) {
    // Vectorize if depth is constant across buffer
    if depth < 16.0 {
        for i in 0..<samples.count {
            samples[i] = bitCrush(samples[i], depth: depth)
        }
    }
}
```

---

## SPECTRAL FEATURE EXTRACTION

### Centroid (Brightness Indicator)

**Weighted average of frequency bins:**

```swift
/// Computes spectral centroid [0..1] where 0=DC, 1=Nyquist.
func computeCentroid(_ magnitudes: [Float]) -> Float {
    var weightedSum: Float = 0.0
    var totalMagnitude: Float = 0.0
    
    for i in 0..<magnitudes.count {
        let mag = max(magnitudes[i], 1e-8)  // Avoid log(0)
        weightedSum += Float(i) * mag
        totalMagnitude += mag
    }
    
    guard totalMagnitude > 1e-6 else { return 0.0 }
    
    let centroid = weightedSum / totalMagnitude
    let normalized = centroid / Float(magnitudes.count)
    
    return normalized  // [0..1]
}
```

**Interpretation:**
- Low centroid (< 0.3): warm, bass-heavy
- Mid centroid (0.3-0.7): balanced
- High centroid (> 0.7): bright, metallic

### Flatness (Noisiness Indicator)

**Geometric mean / arithmetic mean:**

```swift
/// Computes spectral flatness [0..1] where 0=tonal, 1=noise-like.
func computeFlatness(_ magnitudes: [Float]) -> Float {
    var geometricMean: Float = 1.0
    var arithmeticSum: Float = 0.0
    
    for mag in magnitudes {
        let clamped = max(mag, 1e-8)
        geometricMean *= clamped
        arithmeticSum += clamped
    }
    
    // Geometric mean: (product)^(1/N)
    geometricMean = pow(geometricMean, 1.0 / Float(magnitudes.count))
    
    // Arithmetic mean: sum / N
    let arithmeticMean = arithmeticSum / Float(magnitudes.count)
    
    guard arithmeticMean > 1e-6 else { return 0.0 }
    
    let flatness = geometricMean / arithmeticMean
    
    return flatness  // [0..1]
}
```

**Interpretation:**
- Low flatness (< 0.3): harmonic/tonal (pitched)
- Mid flatness (0.3-0.7): textured
- High flatness (> 0.7): noise-like, chaotic

### Flux (Timbral Change Rate)

**Frame-to-frame magnitude difference:**

```swift
private var previousMagnitude: [Float] = []

/// Computes spectral flux (rate of timbral evolution).
func computeFlux(_ magnitudes: [Float]) -> Float {
    guard previousMagnitude.count == magnitudes.count else {
        previousMagnitude = magnitudes
        return 0.0
    }
    
    var sum: Float = 0.0
    
    for i in 0..<magnitudes.count {
        let diff = magnitudes[i] - previousMagnitude[i]
        sum += diff * diff  // Squared difference
    }
    
    previousMagnitude = magnitudes
    
    return sqrt(sum)  // Euclidean distance
}
```

**Interpretation:**
- Low flux (< 10): stable timbre
- High flux (> 50): rapid timbral evolution

**Use case (from whitepaper §2.4):**
- Drive prompt evolution (flux → phase transition)
- Route to parameters (flux → SPECTRAL_NOISE.AMOUNT)
- Display on XY pad (CNT/FLAT mode)

---

## SEMANTIC SPECTRAL EQ (4-BAND)

### Prompt-Driven Frequency Shaping

**From SpectralProcessor.swift — 80+ semantic profiles:**

```swift
// MARK: - Semantic Profiles

/// 4-band spectral gain derived from prompt keywords.
/// [low, lowMid, highMid, high]
private static let semanticProfiles: [String: [Float]] = [
    "moog":       [3.0, 1.8, 0.9, 0.4],  // Heavy sub emphasis
    "acid":       [2.2, 2.5, 1.2, 0.6],  // Mid-heavy squelch
    "buchla":     [0.8, 2.0, 2.2, 1.0],  // Mid pluck
    "metallic":   [0.5, 0.8, 1.5, 2.5],  // High emphasis
    "warm":       [2.5, 1.5, 0.8, 0.4],  // Low emphasis
    "air":        [0.3, 0.4, 1.2, 2.8],  // Extreme highs
    "percussion": [1.5, 2.0, 1.8, 1.2],  // Mid punch
    // ... 70+ more profiles
]

/// Updates spectral profile based on prompt keywords.
func updateSemanticProfile(prompt: String) {
    let lower = prompt.lowercased()
    
    // Search for matching keywords
    for (keyword, profile) in Self.semanticProfiles {
        if lower.contains(keyword) {
            self.spectralProfile = profile
            return
        }
    }
    
    // Default: flat response
    self.spectralProfile = [1.0, 1.0, 1.0, 1.0]
}

/// Applies 4-band EQ to magnitude spectrum.
@inline(__always)
private func applySemanticEQ(magnitudes: inout [Float]) {
    let bandSize = magnitudes.count / 4
    
    for band in 0..<4 {
        let start = band * bandSize
        let end = (band == 3) ? magnitudes.count : (band + 1) * bandSize
        
        var gain = spectralProfile[band]
        
        for i in start..<end {
            magnitudes[i] *= gain
        }
    }
}
```

**Why semantic EQ?**
- Prompt-driven frequency shaping (whitepaper §6.1)
- Each preset has distinct frequency slot (§2.11)
- Prevents all lanes converging to same "reverberant landscape"

---

## SPECTRAL MEMORY (RECURSIVE DRIFT)

### Persistent Magnitude Accumulator

**From SpectralProcessor.swift — the "spectral analogue of latentState":**

```swift
// MARK: - Spectral Memory (Whitepaper §5.4)

/// Persistent spectral magnitude array.
/// Frequencies that persist across iterations are reinforced.
/// This is the DSP analogue of the latent state vector in CoreML.
private var spectralMemory: [Float]

init(...) {
    self.spectralMemory = [Float](repeating: 0, count: halfN)
}

/// Blends current spectrum with persistent memory.
/// coefficient [0..1]: 0=no memory, 1=infinite sustain
@inline(__always)
private func applySpectralMemory(
    magnitudes: inout [Float],
    coefficient: Float
) {
    guard coefficient > 0.01 else { return }
    
    for i in 0..<magnitudes.count {
        // Update memory (exponential moving average)
        spectralMemory[i] = coefficient * spectralMemory[i]
                          + (1.0 - coefficient) * magnitudes[i]
        
        // Blend current with memory
        magnitudes[i] = 0.5 * magnitudes[i] + 0.5 * spectralMemory[i]
    }
}
```

**Result:**
- Resonant frequencies accumulate over time
- Transient energy decays
- Creates "spectral reverb" effect
- Analogous to Lucier's room resonance

---

## SPECTRAL NOISE INJECTION

### Colored Noise in Frequency Domain

**From SpectralProcessor.swift:**

```swift
/// Injects colored noise into spectrum, shaped by semantic profile.
@inline(__always)
private func applySpectralNoise(
    magnitudes: inout [Float],
    amount: Float,
    rng: inout UInt64
) {
    guard amount > 1.0 else { return }
    
    let bandSize = magnitudes.count / 4
    
    for band in 0..<4 {
        let start = band * bandSize
        let end = (band == 3) ? magnitudes.count : (band + 1) * bandSize
        
        // Noise scaling based on semantic profile
        let bandGain = spectralProfile[band]
        let noiseScale = amount * 0.01 * bandGain
        
        for i in start..<end {
            // Generate noise sample
            rng = xoshiro256ss(&rng)
            let noise = Float(rng % 20001) / 10000.0 - 1.0  // [-1..1]
            
            // Add scaled noise to magnitude
            magnitudes[i] += abs(noise) * noiseScale * magnitudes[i]
        }
    }
}
```

**Why colored (not white)?**
- Prompt-dependent: "metallic" → high-freq noise, "warm" → low-freq noise
- Preserves semantic coherence
- Creates textured, not chaotic, result

---

## SPECTRAL GRANULARITY (MICROSOUND)

### Window Sparsification in Frequency Domain

**From SpectralProcessor.swift — Curtis Roads "Microsound" (2001):**

```swift
/// Microsound window sparsification.
/// Keeps only `window` percent of spectrum, zeros the rest.
/// Lower values → granular dust, higher → continuous texture.
@inline(__always)
private func applySpectralGranularity(
    magnitudes: inout [Float],
    window: Float,
    rng: inout UInt64
) {
    guard window < 99.0 else { return }
    
    let keepRatio = window * 0.01  // [0..1]
    
    for i in 0..<magnitudes.count {
        // Stochastic gate: keep bin with probability = keepRatio
        rng = xoshiro256ss(&rng)
        let roll = Float(rng % 10001) / 10000.0
        
        if roll > keepRatio {
            magnitudes[i] = 0.0  // Zero this bin (creates spectral holes)
        }
    }
}
```

**Result:**
- Low granularity (< 30): sparse spectrum, granular dust
- High granularity (> 70): dense spectrum, continuous texture
- Stochastic masking creates microsound windows

---

## SPECTRAL FREEZE (SUSTAINED SNAPSHOT)

### Capture and Blend

**From SpectralProcessor.swift:**

```swift
// MARK: - Spectral Freeze State

private var frozenSpectrum: [Float]?

/// Captures current spectrum as frozen snapshot.
func captureFreeze(magnitudes: [Float]) {
    frozenSpectrum = magnitudes
}

/// Blends current spectrum with frozen snapshot.
/// blend [0..1]: 0=full freeze, 1=no freeze
@inline(__always)
private func applySpectralFreeze(
    magnitudes: inout [Float],
    isActive: Bool,
    blend: Float
) {
    guard isActive, let frozen = frozenSpectrum else { return }
    guard frozen.count == magnitudes.count else { return }
    
    for i in 0..<magnitudes.count {
        magnitudes[i] = blend * magnitudes[i] + (1.0 - blend) * frozen[i]
    }
}
```

**Use case (whitepaper §5.2):**
- Press FREEZE → current spectrum captured
- Subsequent frames blend with snapshot
- Creates sustained "spectral drone"
- Useful for isolating specific resonances

---

## DELAY LINE (RECURSIVE FEEDBACK)

### Circular Buffer Implementation

```swift
// MARK: - Delay Line State

private var delayBuffer: [Float]
private var delayWritePos: Int = 0
private let delayMaxLength: Int

init(...) {
    // Max delay: 2 seconds at 48kHz
    self.delayMaxLength = Int(sampleRate * 2.0)
    self.delayBuffer = [Float](repeating: 0, count: delayMaxLength)
}

/// Processes delay with configurable time and feedback.
@inline(__always)
private func delaySample(
    _ input: Float,
    time: Float,      // seconds [0.01..2.0]
    feedback: Float,  // [0..0.95]
    mix: Float        // dry/wet [0..1]
) -> Float {
    // Time to samples
    let delaySamples = Int(time * Float(sampleRate))
    let clampedDelay = min(delaySamples, delayMaxLength - 1)
    
    // Read delayed sample
    let readIndex = (delayWritePos - clampedDelay + delayMaxLength) % delayMaxLength
    let delayed = delayBuffer[readIndex]
    
    // Write with feedback
    delayBuffer[delayWritePos] = input + delayed * feedback
    delayWritePos = (delayWritePos + 1) % delayMaxLength
    
    // Dry/wet mix
    return input * (1.0 - mix) + delayed * mix
}
```

**Feedback constraint:**
- Max feedback = 0.95 (prevents infinite growth)
- Higher feedback → longer decay, more "infinite" feel
- Lower feedback → shorter decay, clearer transients

---

## SPECTRAL SATURATION (PER-BAND HARMONIC ENRICHMENT)

### Frequency-Domain Harmonic Generation

```swift
/// Applies per-band saturation in spectral domain.
/// drive [0..1]: adds harmonics to each band proportionally.
@inline(__always)
private func applySpectralSaturation(
    magnitudes: inout [Float],
    drive: Float
) {
    guard drive > 0.01 else { return }
    
    for i in 0..<magnitudes.count {
        let mag = magnitudes[i]
        
        // Soft saturation curve: y = x * (1 + drive * x)
        // Creates even harmonics in frequency domain
        magnitudes[i] = mag * (1.0 + drive * mag * 0.5)
    }
}
```

**Why in spectral domain?**
- Per-band control (semantic EQ interaction)
- Creates complex harmonic interactions
- Cheaper than time-domain oversampling

---

## PARAMETER RANGE DESIGN

### Design Ranges for Knob Feel

**Exponential parameters (CFG, frequency):**

```swift
// Linear knob → exponential parameter
let linearKnob: Float = 0.5  // [0..1]

// Map to exponential range [20..20000 Hz]
let minLog = log(20.0)
let maxLog = log(20000.0)
let logValue = minLog + linearKnob * (maxLog - minLog)
let frequency = exp(logValue)

// Result: 0.5 knob → ~632 Hz (geometric center)
```

**Why exponential?**
- Human pitch perception is logarithmic
- Equal knob increments = equal perceived change
- Covers wide range without dead zones

**Linear parameters (gain, mix):**

```swift
// Linear knob → linear parameter
let mix: Float = knobValue  // [0..1]
let output = drySignal * (1.0 - mix) + wetSignal * mix
```

**Why linear?**
- Mix, volume, and blend are perceptually linear
- 50% knob = 50% mix (intuitive)

### Constants.swift Range Definitions

```swift
// Exponential ranges
static let filterCutoffRange: ClosedRange<Float> = 20.0...20000.0
static let cfgScaleRange: ClosedRange<Float> = 3.0...20.0

// Linear ranges
static let feedbackRange: ClosedRange<Float> = 0.0...1.0
static let delayMixRange: ClosedRange<Float> = 0.0...1.0
```

---

## ADVANCED: POLYBLEP ANTI-ALIASING

### Reducing Aliasing in Waveforms

**For sawtooth, square, pulse waves with band-limited synthesis:**

```swift
/// PolyBLEP (Polynomial Bandlimited Step) anti-aliasing.
/// Smooths discontinuities to reduce aliasing.
@inline(__always)
private func polyblep(_ phase: Float, _ phaseIncrement: Float) -> Float {
    // Transition region size
    let dt = phaseIncrement
    
    // Start of discontinuity
    if phase < dt {
        let t = phase / dt
        return t + t - t * t - 1.0
    }
    // End of discontinuity
    else if phase > 1.0 - dt {
        let t = (phase - 1.0) / dt
        return t * t + t + t + 1.0
    }
    
    return 0.0
}

/// Band-limited sawtooth with PolyBLEP.
func generateSawtooth(frequency: Float, sampleRate: Float) -> [Float] {
    var output = [Float](repeating: 0, count: bufferSize)
    let phaseIncrement = frequency / sampleRate
    var phase: Float = 0.0
    
    for i in 0..<bufferSize {
        // Naive sawtooth
        var sample = 2.0 * phase - 1.0
        
        // Apply PolyBLEP correction at discontinuity
        sample -= polyblep(phase, phaseIncrement)
        
        output[i] = sample
        
        phase += phaseIncrement
        if phase >= 1.0 { phase -= 1.0 }
    }
    
    return output
}
```

**When to use:**
- Oscillators with sharp discontinuities (saw, square, pulse)
- Prevents aliasing (mirror frequencies > Nyquist)
- Cleaner sound at high frequencies

---

## TESTING DSP CODE

### Unit Test Pattern

```swift
final class SpectralProcessorTests: XCTestCase {
    
    var processor: SpectralProcessor!
    
    override func setUp() {
        processor = SpectralProcessor(fftSize: 1024, sampleRate: 48000)
    }
    
    // Test 1: Zero input → zero output
    func testSilencePassthrough() {
        var samples = [Float](repeating: 0, count: 1024)
        processor.process(samples: &samples)
        
        // Allow tiny numerical error
        for sample in samples {
            XCTAssertLessThan(abs(sample), 1e-6)
        }
    }
    
    // Test 2: No NaN/Inf under stress
    func testNoNaNUnderStress() {
        var samples = [Float](repeating: 1.0, count: 1024)
        
        // Extreme parameters
        processor.process(
            samples: &samples,
            entropy: 100.0,
            granularity: 100.0,
            filterCutoff: 20.0,
            filterResonance: 0.95
        )
        
        // Validate
        for sample in samples {
            XCTAssertFalse(sample.isNaN)
            XCTAssertFalse(sample.isInfinite)
        }
    }
    
    // Test 3: Energy preservation (Parseval's theorem)
    func testEnergyPreservation() {
        // Generate sine wave
        var samples = generateSine(frequency: 440, duration: 1024)
        
        let inputEnergy = samples.reduce(0) { $0 + $1 * $1 }
        
        // Process (with minimal destructive operations)
        processor.process(samples: &samples)
        
        let outputEnergy = samples.reduce(0) { $0 + $1 * $1 }
        
        // Energy should be approximately preserved (allow 10% variance)
        XCTAssertEqual(outputEnergy, inputEnergy, accuracy: inputEnergy * 0.1)
    }
}
```

---

## QUICK REFERENCE: DSP FORMULAS

### Filter Coefficient Calculation

**1-pole lowpass:**
```swift
let fc = cutoffFrequency / sampleRate  // Normalized frequency
let coefficient = exp(-2.0 * .pi * fc)
output = coefficient * state + (1.0 - coefficient) * input
state = output
```

**1-pole highpass:**
```swift
let fc = cutoffFrequency / sampleRate
let coefficient = exp(-2.0 * .pi * fc)
output = input - coefficient * state
state = output
```

### MIDI Note to Frequency

```swift
func midiToFreq(_ note: Float) -> Float {
    return 440.0 * pow(2.0, (note - 69.0) / 12.0)
}

// Middle C (MIDI 60) → 261.63 Hz
// A4 (MIDI 69) → 440 Hz
```

### Frequency to Delay Samples

```swift
func freqToDelaySamples(_ freq: Float, sampleRate: Float) -> Int {
    return Int(sampleRate / freq)
}

// 440 Hz at 48kHz → 109 samples delay
```

### RMS Calculation (Manual)

```swift
func computeRMS(_ samples: [Float]) -> Float {
    var sum: Float = 0.0
    for sample in samples {
        sum += sample * sample
    }
    return sqrt(sum / Float(samples.count))
}

// Or use vDSP (much faster):
var rms: Float = 0
vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
```

### Decibel Conversion

```swift
// Linear to dB
func linearToDb(_ linear: Float) -> Float {
    return 20.0 * log10(max(linear, 1e-8))
}

// dB to linear
func dbToLinear(_ db: Float) -> Float {
    return pow(10.0, db / 20.0)
}

// Example: -6 dB = 0.501 linear gain (half power)
```

---

## COMMON DSP MISTAKES

### Mistake 1: Forgetting IFFT Normalization

```swift
// ❌ WRONG — output is 2N times too loud
vDSP_fft_zrip(fftSetup, &complex, 1, log2n, FFTDirection(FFT_INVERSE))

// ✓ CORRECT — scale by 1/(2*N)
vDSP_fft_zrip(fftSetup, &complex, 1, log2n, FFTDirection(FFT_INVERSE))
var scale = Float(1.0) / Float(2 * fftSize)
vDSP_vsmul(realPart, 1, &scale, &realPart, 1, vDSP_Length(halfN))
```

### Mistake 2: Phase Discontinuity on Parameter Change

```swift
// ❌ WRONG — phase jumps when frequency changes
func generateOscillator(frequency: Float) -> Float {
    phase = 0.0  // RESET → click
    phase += 2.0 * .pi * frequency / sampleRate
    return sin(phase)
}

// ✓ CORRECT — phase continues
func generateOscillator(frequency: Float) -> Float {
    let phaseIncrement = 2.0 * .pi * frequency / sampleRate
    phase += phaseIncrement  // Continuous
    if phase > 2.0 * .pi { phase -= 2.0 * .pi }
    return sin(phase)
}
```

### Mistake 3: Resonance Explosion

```swift
// ❌ WRONG — feedback > 1.0 causes exponential growth
let feedback: Float = 1.2  // UNSTABLE

// ✓ CORRECT — clamp to prevent explosion
let feedback = min(feedbackParam, 0.99)  // Safe maximum
```

### Mistake 4: DC Offset Accumulation

```swift
// ❌ WRONG — small DC offsets accumulate in feedback loops
let output = process(input)
feedbackBuffer = output  // Contains DC → grows unbounded

// ✓ CORRECT — DC blocking filter
let output = process(input)
let blocked = blockDC(output)  // Remove DC before feedback
feedbackBuffer = blocked
```

---

## PERFORMANCE BENCHMARKS

**Target: < 5ms per buffer (512 samples at 48kHz)**

### SpectralProcessor Breakdown (from profiling)

```
Operation                    Time (ms)   % of Budget
─────────────────────────────────────────────────────
Extract chunk + window          0.2       4%
Forward FFT (1024-point)        0.8      16%
Cartesian → Polar               0.3       6%
Semantic EQ (4-band)            0.2       4%
Spectral Saturation             0.1       2%
Spectral Noise                  0.3       6%
Spectral Memory                 0.2       4%
Spectral Granularity            0.2       4%
Polar → Cartesian               0.3       6%
Inverse FFT                     0.8      16%
Overlap-add                     0.2       4%
Ladder Filter (4-pole)          0.4       8%
Comb Filters (5 taps)           0.3       6%
Tunable Resonator               0.2       4%
Bit Crusher                     0.1       2%
Waveshaper                      0.2       4%
─────────────────────────────────────────────────────
TOTAL                           4.8 ms   96%
```

**Remaining 4% = safety margin for parameter smoothing, validation.**

**If adding a stage, budget is ~0.2ms max.**

---

## WHEN TO USE EACH TECHNIQUE

### Use FFT/IFFT When:
- Need frequency-selective processing (EQ, spectral effects)
- Want magnitude-only processing (preserve phase)
- Processing full spectrum (not single frequencies)

### Use Time-Domain Filters When:
- Need sample-accurate response (ladder filter)
- Want analog modeling (saturation, distortion)
- Processing single samples in series

### Use Circular Buffers When:
- Need delays, reverbs, feedback paths
- Want pitch shifting (with interpolation)
- Creating comb filters, chorus, flangers

### Use vDSP When:
- Operating on arrays/vectors (not single samples)
- Need SIMD acceleration (4-8x speedup)
- Doing vector math (multiply, add, scale)

---

## FINAL DSP CHECKLIST

**Before committing DSP code:**

- [ ] All buffers pre-allocated
- [ ] Parameters smoothed (1-pole LP, coeff 0.15)
- [ ] NaN/Inf validated before output
- [ ] vDSP used for vector operations
- [ ] Ranges clamped (min/max on inputs)
- [ ] Feedback < 1.0 (prevent explosion)
- [ ] DC blocking if feedback path
- [ ] Phase continuity on param changes
- [ ] Profiled (< 5ms callback time)
- [ ] Sounds correct (no clicks, pops, glitches)

**If any checkbox fails, debug before merging.**

---

## THE SPECTRAL PROCESSOR IS THE SOUL

**From whitepaper §6.1:**

> "When Core ML models are unavailable, SpectralProcessor IS the 'Black Box Resonator,' creating recursive degradation entirely in the spectral domain. The spectralMemory array is the DSP analogue of the latentState vector in CoreMLInference."

**This is not just a fallback. It's a fundamental mode.**

- Neural inference ADDS capability
- But DSP-only mode is a complete instrument
- Spectral memory = latent drift in frequency domain
- Semantic EQ = prompt-driven filtering

**The DSP path is the foundation. Protect it. Optimize it. Respect it.**
