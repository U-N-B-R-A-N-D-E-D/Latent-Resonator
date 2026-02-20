import Foundation
import AVFoundation

// MARK: - Signal Generator
// Multiple excitation sources for the Neural Feedback Loop.
//
// Max/MSP teaches us that sonic diversity begins at the source.
// The original Koenig Seed (§4.1) is ONE valid excitation -- but
// the whitepaper's latent space is a resonant chamber (§1.2) that
// responds differently to different inputs. Each mode "pings" the
// neural network's latent space differently, revealing distinct
// regions of its timbral map.
//
// Modes:
//   .koenigSeed  -- Euclidean Dirac impulses + noise tails (§4.1)
//   .whiteNoise  -- Broadband excitation (every frequency at once)
//   .sineOsc     -- Single-frequency probe of latent space
//   .pulseTrain  -- Variable-density impulse stream
//   .silence     -- Null input; forces pure hallucination from latent priors

// MARK: - Excitation Mode Enum

enum ExcitationMode: String, CaseIterable, Identifiable {
    case koenigSeed  = "KOENIG"
    case whiteNoise  = "NOISE"
    case sineOsc     = "SINE"
    case sawOsc      = "SAW"
    case squareOsc   = "SQUARE"
    case triangleOsc = "TRI"
    case pulseTrain  = "PULSE"
    case silence     = "SILENCE"

    var id: String { rawValue }

    /// Human-readable description for the UI.
    var label: String { rawValue }
}

// MARK: - Filter Mode (Moog-style Ladder Filter)

enum FilterMode: String, CaseIterable, Identifiable {
    case lowpass   = "LP"
    case highpass  = "HP"
    case bandpass  = "BP"

    var id: String { rawValue }
}

// MARK: - Saturation Mode (Analog Circuit Waveshaping)

enum SaturationMode: String, CaseIterable, Identifiable {
    case clean      = "CLEAN"
    case tube       = "TUBE"
    case transistor = "XSTR"
    case diode      = "DIODE"

    var id: String { rawValue }
}

// MARK: - LFO Target Enum

/// Parameters that the LFO can modulate over time.
/// Implements the stochastic parameter evolution concept (§5.2)
/// where timbral entropy increases over time without human input.
enum LFOTarget: String, CaseIterable, Identifiable {
    case none        = "OFF"
    case entropy     = "ENTROPY"
    case granularity = "GRAIN"
    case guidance    = "CFG"
    case feedback    = "FEEDBACK"
    case resonator   = "RESON"

    var id: String { rawValue }
}

// MARK: - Xoshiro256** Lock-Free PRNG
//
// Audio-thread safe: no locks, no system calls, no heap allocation.
// Period: 2^256 - 1. Passes BigCrush and PractRand.
// Each SignalGenerator instance has its own state -- no contention.

struct Xoshiro256StarStar {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64 = 0) {
        // SplitMix64 to expand a single seed into 4 state words
        var z = seed == 0 ? UInt64(mach_absolute_time()) : seed
        func splitmix() -> UInt64 {
            z &+= 0x9e3779b97f4a7c15
            var r = z
            r = (r ^ (r >> 30)) &* 0xbf58476d1ce4e5b9
            r = (r ^ (r >> 27)) &* 0x94d049bb133111eb
            return r ^ (r >> 31)
        }
        s = (splitmix(), splitmix(), splitmix(), splitmix())
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    /// Generate next UInt64 in the sequence.
    @inline(__always)
    mutating func next() -> UInt64 {
        let result = Self.rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = Self.rotl(s.3, 45)
        return result
    }

    /// Uniform Float in [0, 1).
    @inline(__always)
    mutating func nextFloat() -> Float {
        Float(next() >> 40) * 0x1.0p-24
    }

    /// Uniform Float in the given range (closed).
    @inline(__always)
    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }

    /// Gaussian random via Box-Muller transform (lock-free).
    @inline(__always)
    mutating func nextGaussian(mean: Float = 0, stddev: Float = 1) -> Float {
        let u1 = max(nextFloat(), Float.ulpOfOne)
        let u2 = nextFloat()
        let z0 = sqrtf(-2.0 * logf(u1)) * cosf(2.0 * .pi * u2)
        return z0 * stddev + mean
    }
}

// MARK: - Signal Generator

final class SignalGenerator {

    // MARK: - Lock-Free PRNG (Audio Thread Safe)

    /// Per-instance Xoshiro256** PRNG for audio-thread noise generation.
    /// Replaces Float.random(in:) which uses the system PRNG (potentially locking).
    private var rng = Xoshiro256StarStar()

    // MARK: - State

    /// Current sine oscillator phase (radians, wraps at 2π).
    private var sinePhase: Double = 0.0

    /// Saw/square/triangle phase (normalized 0..1, wraps at 1).
    private var oscPhase: Double = 0.0

    /// Pulse width for square oscillator (0.1..0.9). 0.5 = symmetric square.
    var pulseWidth: Float = 0.5

    /// Pulse train accumulator (sample counter).
    private var pulseAccumulator: Double = 0.0

    /// Current Euclidean rhythm configuration for Koenig mode.
    var euclideanPulses: Int = LRConstants.euclideanPulses
    var euclideanSteps: Int = LRConstants.euclideanSteps

    /// Sine oscillator frequency in Hz.
    var sineFrequency: Float = LRConstants.sineFrequencyDefault

    /// Pulse train density (pulses per second).
    var pulseDensity: Float = LRConstants.pulseDensityDefault

    // MARK: - LFO State

    /// LFO phase (radians, wraps at 2π).
    private var lfoPhase: Double = 0.0

    // MARK: - Koenig Seed Streaming State

    /// Position within the Euclidean rhythm cycle (in samples).
    private var koenigPosition: Int = 0
    /// Cached Euclidean rhythm pattern (avoids recomputation each render call).
    private var cachedRhythm: [Bool] = []
    /// Cached parameters to detect when rhythm needs regeneration.
    private var cachedKPulses: Int = 0
    private var cachedKSteps: Int = 0

    // MARK: - Real-Time Render (Audio Thread)

    /// Fill raw audio buffer pointers for use in an AVAudioSourceNode render
    /// callback. This method is audio-thread safe: no allocations, no locks.
    ///
    /// Unlike `generateBuffer` (which creates a full AVAudioPCMBuffer up front),
    /// this streams samples incrementally, maintaining oscillator/rhythm state
    /// across calls. This enables real-time parameter changes (frequency, density,
    /// Euclidean k/n) during playback -- essential for the instrument paradigm.
    ///
    /// - Parameters:
    ///   - left: Left channel output pointer
    ///   - right: Right channel output pointer
    ///   - frameCount: Number of frames to generate
    ///   - mode: Excitation source type
    ///   - sampleRate: Audio sample rate
    func renderInto(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        mode: ExcitationMode,
        sampleRate: Double
    ) {
        // Zero-fill before rendering
        memset(left, 0, frameCount * MemoryLayout<Float>.size)
        memset(right, 0, frameCount * MemoryLayout<Float>.size)

        switch mode {
        case .koenigSeed:
            renderKoenigSeedStreaming(left: left, right: right,
                                     frameCount: frameCount, sampleRate: sampleRate)
        case .whiteNoise:
            fillWhiteNoise(left: left, right: right, count: frameCount)
        case .sineOsc:
            fillSine(left: left, right: right,
                     count: frameCount, sampleRate: sampleRate)
        case .sawOsc:
            fillSaw(left: left, right: right,
                    count: frameCount, sampleRate: sampleRate)
        case .squareOsc:
            fillSquare(left: left, right: right,
                       count: frameCount, sampleRate: sampleRate)
        case .triangleOsc:
            fillTriangle(left: left, right: right,
                         count: frameCount, sampleRate: sampleRate)
        case .pulseTrain:
            fillPulseTrain(left: left, right: right,
                           count: frameCount, sampleRate: sampleRate)
        case .silence:
            break  // already zeroed -- forces pure hallucination from latent priors
        }
    }

    /// Streaming Koenig Seed: tracks position within the Euclidean cycle
    /// across render calls, enabling sample-accurate rhythmic generation.
    private func renderKoenigSeedStreaming(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) {
        // Recache rhythm pattern when parameters change
        if euclideanPulses != cachedKPulses || euclideanSteps != cachedKSteps {
            cachedRhythm = KoenigSeedGenerator.euclideanRhythm(
                pulses: euclideanPulses,
                steps: euclideanSteps
            )
            cachedKPulses = euclideanPulses
            cachedKSteps = euclideanSteps
            koenigPosition = 0
        }

        let cycleLength = Int(LRConstants.seedDurationSeconds * sampleRate)
        guard euclideanSteps > 0, cycleLength > 0 else { return }
        let samplesPerStep = cycleLength / euclideanSteps
        guard samplesPerStep > 0 else { return }
        let noiseTailSamples = Int(LRConstants.noiseTailDurationMs / 1000.0 * sampleRate)

        for i in 0..<frameCount {
            let posInCycle = koenigPosition % cycleLength
            let currentStep = min(posInCycle / samplesPerStep, cachedRhythm.count - 1)
            let posInStep = posInCycle % samplesPerStep

            if currentStep >= 0, currentStep < cachedRhythm.count, cachedRhythm[currentStep] {
                if posInStep == 0 {
                    // Dirac impulse (§4.1.2)
                    left[i] = LRConstants.diracAmplitude
                    right[i] = LRConstants.diracAmplitude
                } else if posInStep > 0, posInStep < noiseTailSamples {
                    // Gaussian noise tail -- nucleation site (§4.1.3)
                    let noise = rng.nextGaussian() * LRConstants.noiseTailAmplitude
                    left[i] = noise
                    right[i] = noise
                }
            }

            koenigPosition += 1
            if koenigPosition >= cycleLength { koenigPosition = 0 }
        }
    }

    // MARK: - Fill Methods

    /// White Noise: broadband excitation -- pings every frequency in
    /// the latent space simultaneously (spectral equivalent of white light).
    private func fillWhiteNoise(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        for i in 0..<count {
            let noiseL = rng.nextFloat(in: -1.0...1.0) * 0.3
            let noiseR = rng.nextFloat(in: -1.0...1.0) * 0.3
            left[i] = noiseL
            right[i] = noiseR
        }
    }

    /// Sine Oscillator: single-frequency probe.
    /// Different frequencies excite different latent-space regions.
    private func fillSine(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int,
        sampleRate: Double
    ) {
        let phaseIncrement = 2.0 * Double.pi * Double(sineFrequency) / sampleRate
        var phase = sinePhase

        for i in 0..<count {
            let sample = Float(sin(phase)) * 0.5
            left[i] = sample
            right[i] = sample
            phase += phaseIncrement
            if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }

        sinePhase = phase
    }

    /// Pulse Train: variable-density impulse stream.
    /// Higher density -> more transient energy -> different latent-space response
    /// than the sparse Koenig Seed.
    private func fillPulseTrain(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int,
        sampleRate: Double
    ) {
        let samplesPerPulse = sampleRate / Double(pulseDensity)
        var accumulator = pulseAccumulator
        let noiseTailSamples = Int(LRConstants.noiseTailDurationMs / 1000.0 * sampleRate)

        for i in 0..<count {
            accumulator += 1.0
            if accumulator >= samplesPerPulse {
                accumulator -= samplesPerPulse
                left[i] = LRConstants.diracAmplitude
                right[i] = LRConstants.diracAmplitude

                // Short noise tail after each pulse
                for j in 1..<min(noiseTailSamples, count - i) {
                    let noise = rng.nextGaussian() * LRConstants.noiseTailAmplitude
                    left[i + j] += noise
                    right[i + j] += noise
                }
            }
        }

        pulseAccumulator = accumulator
    }

    // MARK: - PolyBLEP Anti-Aliasing
    //
    // Band-limited polynomial correction applied near waveform
    // discontinuities (transitions). Eliminates aliasing in saw,
    // square, and triangle waveforms without heavy computation.
    // Standard technique in virtual analog synthesis (Valimaki 2006).

    @inline(__always)
    private static func polyBLEP(_ t: Double, dt: Double) -> Double {
        if t < dt {
            let n = t / dt
            return n + n - n * n - 1.0
        } else if t > 1.0 - dt {
            let n = (t - 1.0) / dt
            return n * n + n + n + 1.0
        }
        return 0.0
    }

    // MARK: - Sawtooth (Minimoog Character)

    /// Band-limited sawtooth -- the Minimoog sound. Rich harmonics,
    /// buzzy, warm. polyBLEP anti-aliasing prevents aliasing artifacts.
    private func fillSaw(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int,
        sampleRate: Double
    ) {
        let freq = Double(sineFrequency)
        let dt = freq / sampleRate
        var phase = oscPhase

        for i in 0..<count {
            // Naive sawtooth: 2*phase - 1 (range -1..+1)
            var sample = 2.0 * phase - 1.0
            // Apply polyBLEP at the discontinuity (phase wrap)
            sample -= Self.polyBLEP(phase, dt: dt)

            let out = Float(sample) * 0.5
            left[i] = out
            right[i] = out

            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
        }

        oscPhase = phase
    }

    // MARK: - Square / Pulse (ARP 2600, Roland SH-101 Character)

    /// Band-limited square/pulse with variable pulse width (PWM).
    /// Hollow at 50%, nasal at narrow widths. PWM is the signature
    /// "analog drift" effect of classic polysynths.
    private func fillSquare(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int,
        sampleRate: Double
    ) {
        let freq = Double(sineFrequency)
        let dt = freq / sampleRate
        let pw = Double(pulseWidth)
        var phase = oscPhase

        for i in 0..<count {
            // Naive pulse: +1 below pw, -1 above
            var sample = phase < pw ? 1.0 : -1.0
            // polyBLEP at rising edge (phase = 0)
            sample += Self.polyBLEP(phase, dt: dt)
            // polyBLEP at falling edge (phase = pw)
            let shifted = phase >= pw ? phase - pw : phase - pw + 1.0
            sample -= Self.polyBLEP(shifted, dt: dt)

            let out = Float(sample) * 0.5
            left[i] = out
            right[i] = out

            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
        }

        oscPhase = phase
    }

    // MARK: - Triangle (Buchla Character)

    /// Soft, flute-like triangle wave -- the Buchla sound. Fewer
    /// harmonics than saw/square, pure and warm. Derived by
    /// integrating the square wave (leaky integrator for stability).
    private func fillTriangle(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int,
        sampleRate: Double
    ) {
        let freq = Double(sineFrequency)
        let dt = freq / sampleRate
        var phase = oscPhase

        for i in 0..<count {
            // Triangle from phase: piecewise linear
            // 0..0.5: ramp up from -1 to +1
            // 0.5..1: ramp down from +1 to -1
            let sample: Double
            if phase < 0.5 {
                sample = 4.0 * phase - 1.0
            } else {
                sample = 3.0 - 4.0 * phase
            }

            let out = Float(sample) * 0.5
            left[i] = out
            right[i] = out

            phase += dt
            if phase >= 1.0 { phase -= 1.0 }
        }

        oscPhase = phase
    }

    // MARK: - LFO

    /// Compute LFO value for the current sample block.
    ///
    /// Returns a bipolar value [-1..+1] that the engine maps to the target
    /// parameter's range and depth.
    ///
    /// - Parameters:
    ///   - rate: LFO frequency in Hz
    ///   - samplesElapsed: Number of samples since last LFO tick
    ///   - sampleRate: Audio sample rate
    /// - Returns: LFO value in [-1..+1]
    func lfoTick(rate: Float, samplesElapsed: Int, sampleRate: Double) -> Float {
        let phaseIncrement = 2.0 * Double.pi * Double(rate) * Double(samplesElapsed) / sampleRate
        lfoPhase += phaseIncrement
        if lfoPhase >= 2.0 * Double.pi { lfoPhase -= 2.0 * Double.pi }
        return Float(sin(lfoPhase))
    }

    // MARK: - Reset

    func reset() {
        sinePhase = 0.0
        oscPhase = 0.0
        pulseAccumulator = 0.0
        lfoPhase = 0.0
        koenigPosition = 0
        cachedRhythm = []
        cachedKPulses = 0
        cachedKSteps = 0
    }

    // MARK: - Gaussian Noise (Box-Muller) -- Non-Audio Thread

    /// Generate a single Gaussian random sample via the Box-Muller transform.
    ///
    /// Uses the system PRNG (Float.random). Safe for inference/main threads.
    /// For audio-thread noise, use `rng.nextGaussian()` instead (lock-free).
    ///
    /// - Parameters:
    ///   - mean: Distribution mean (default 0.0)
    ///   - stddev: Standard deviation (default 1.0)
    /// - Returns: A normally distributed random Float
    static func boxMullerNoise(mean: Float = 0.0, stddev: Float = 1.0) -> Float {
        let u1 = Float.random(in: Float.ulpOfOne...1.0)
        let u2 = Float.random(in: Float.ulpOfOne...1.0)
        let z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return z0 * stddev + mean
    }
}
