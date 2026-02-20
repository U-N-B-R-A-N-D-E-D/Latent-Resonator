import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Latent Resonator Constants
// All tuning parameters in one place. No magic numbers.
//
// Defaults are aligned with the white paper:
// "Recursive Latent Trajectories in Neural Audio Synthesis"
// --  CFG 15.0-18.0, inputStrength 0.60 -> 0.45, E(5,13) Koenig Seed.

enum LRConstants {

    // MARK: - Audio

    static let sampleRate: Double = 48000.0
    /// Buffer size: 1 second of audio at 48kHz.
    /// Gives ACE-Step meaningful input (was 4096 = 85ms -> 10s mismatch).
    static let bufferSize: Int = 48000
    static let channelCount: Int = 2

    // MARK: - Euclidean Rhythm (Koenig Seed)

    static let euclideanPulses: Int = 5
    static let euclideanSteps: Int = 13
    static let seedDurationSeconds: Double = 10.0
    static let noiseTailDurationMs: Double = 20.0
    static let diracAmplitude: Float = 1.0
    static let noiseTailAmplitude: Float = 0.01

    // MARK: - Neural Inference Parameters

    /// CFG range: 3-20. Below 3 is near-silence; 10 is unity gain with
    /// the exponential curve pow(cfg/10, 1.5). White paper §4.2.1 sweet
    /// spot (15-18) is now the upper "saturation" zone.
    static let cfgScaleRange: ClosedRange<Float> = 3.0...20.0
    /// Default guidance: 10.0 -- unity gain. Push up for saturation,
    /// pull down for clean. Every position sounds distinct.
    static let cfgScaleDefault: Float = 10.0

    static let feedbackRange: ClosedRange<Float> = 0.0...1.0
    /// Default feedback: 0.5 -- active loop from the start.
    static let feedbackDefault: Float = 0.5

    static let entropyRange: ClosedRange<Float> = 0.0...100.0
    /// Default entropy: 35 -- starts in the "textured" zone where spectral
    /// noise is clearly audible. Was 25 (inaudible in real-time DSP path).
    static let entropyDefault: Float = 35.0

    static let granularityRange: ClosedRange<Float> = 0.0...100.0
    static let granularityDefault: Float = 45.0

    /// Input Strength: controls the blend of fresh vs. recursive signal.
    /// White paper §4.2.1: 0.60 initial, §4.2.2: 0.45 for recursive drift.
    static let inputStrengthRange: ClosedRange<Float> = 0.0...1.0
    static let inputStrengthDefault: Float = 0.6

    static let inferenceSteps: Int = 8
    static let latentDimensions: Int = 64

    // MARK: - ACE-Step 1.5 Native Parameters
    //
    // Introduced in the multi-lane upgrade to expose the full ACE-Step 1.5
    // parameter set per-lane. These align with the Tutorial.md specification:
    //   - task_type: cover, repaint, lego, extract, complete
    //   - thinking: bypass LM planner (§6.1 "circumventing the LM")
    //   - shift: attention allocation (structure <-> detail)
    //   - infer_method: ode (deterministic) vs sde (stochastic)

    /// Default task type for the ACE-Step pipeline.
    /// "cover" -- transforms input audio while preserving structure.
    static let aceTaskTypeDefault: String = "cover"

    /// Bypass the LM planner for deterministic parameter control (§6.1).
    /// When false, prompts are injected directly into the DiT.
    static let aceThinkingDefault: Bool = false

    /// Shift: attention allocation weight.
    /// Low (1.0) = structure/form, High (10.0) = texture/detail.
    static let aceShiftRange: ClosedRange<Float> = 1.0...10.0
    static let aceShiftDefault: Float = 5.0

    /// Inference method: deterministic or stochastic diffusion.
    /// "ode" -- deterministic (reproducible), "sde" -- stochastic (entropy injection)
    static let aceInferMethodDefault: String = "ode"

    /// Diffusion steps range. Base model supports 1-100.
    /// Fewer steps = faster but less refined. More steps = slower but richer.
    static let aceStepsRange: ClosedRange<Int> = 4...100
    /// Default: 8 steps -- keeps CPU inference fast enough so the audio thread can breathe.
    /// Raise to 15-25 when using MPS (GPU) or on fast machines.
    static let aceStepsDefault: Int = 8

    // MARK: - Multi-Lane Architecture

    /// Maximum number of simultaneous lanes.
    /// 4 lanes keeps CPU/GPU load manageable. With MPS inference (~5s/step),
    /// 4 lanes cycle in ~20s total. Beyond 4, IOWorkLoop overload occurs.
    static let maxLanes: Int = 4

    /// Default number of lanes created on app launch.
    static let defaultLaneCount: Int = 1

    // MARK: - Latent Pipeline (ACE-Step Three-Model Architecture)

    /// Sequence length for the DiT diffusion transformer (matches conversion script).
    static let latentSequenceLength: Int = 1024
    /// Number of input channels for the VAE encoder (stereo).
    static let vaeInputChannels: Int = 2
    /// Default semantic prompt for conceptual filtering (white paper §4.2.1).
    static let defaultPrompt: String =
        "granular synthesis, comb filter resonance, metallic decay, non-linear distortion, ferrofluid texture"

    // MARK: - Prompt Evolution (White Paper §4.2.2)
    // The prompt shifts across iterations to steer toward entropy maximization.
    // Per-lane prompt phases are now defined in each LanePreset (see below),
    // giving each lane its own evolutionary trajectory through latent space.

    // MARK: - Feedback Loop

    /// Blend weight for fresh audio input in the latent mix.
    static let audioInputStrength: Float = 0.6
    /// Blend weight for recursive latent state in the latent mix.
    static let recursiveInputStrength: Float = 0.45

    // MARK: - DSP Spectral Processor

    /// Number of comb filter taps for metallic resonance.
    static let combFilterTaps: Int = 5
    /// Base delay (in samples) for the comb filter. Creates metallic sheen.
    static let combBaseDelay: Int = 137    // prime number for inharmonicity
    /// Comb filter feedback gain per tap. 0.78 gives a clear metallic ring
    /// that responds audibly to CFG changes. Was 0.65 (too subtle).
    static let combFeedback: Float = 0.78
    /// FFT size for spectral processing (must be power of 2).
    /// 1024 keeps each render callback under ~3ms on Apple Silicon
    /// while still providing ~46.9 Hz spectral resolution at 48 kHz
    /// -- more than adequate for the 4-band semantic EQ.
    static let fftSize: Int = 1024
    /// Log2 of FFT size.
    static let fftLog2n: Int = 10   // log2(1024)
    /// Spectral smoothing coefficient for recursive spectral memory.
    /// 0.85 gives stronger spectral persistence -- frequencies that recur
    /// across iterations build up more obviously, making the recursive
    /// drift audible to the performer. Was 0.7 (too subtle).
    static let spectralMemoryCoeff: Float = 0.85

    // MARK: - Signal Generator (Max/MSP Excitation Sources)

    /// Sine oscillator frequency range (Hz). Covers sub-bass to mid-range.
    static let sineFrequencyRange: ClosedRange<Float> = 20.0...2000.0
    static let sineFrequencyDefault: Float = 110.0

    /// Pulse train density: pulses per second.
    static let pulseDensityRange: ClosedRange<Float> = 0.5...100.0
    static let pulseDensityDefault: Float = 8.0

    /// Configurable Euclidean rhythm bounds (k pulses, n steps).
    static let euclideanPulsesRange: ClosedRange<Int> = 1...16
    static let euclideanStepsRange: ClosedRange<Int> = 2...32

    // MARK: - Effects Chain

    /// Delay time in seconds (The Lucier Chamber -- §1.2).
    static let delayTimeRange: ClosedRange<Float> = 0.01...2.0
    static let delayTimeDefault: Float = 0.25

    /// Delay feedback (recursive decay). 0 = single echo, 1.0 = infinite.
    static let delayFeedbackRange: ClosedRange<Float> = 0.0...0.95
    /// Default 0.6: enough repeats to hear rhythmic echoes from the start.
    static let delayFeedbackDefault: Float = 0.6

    /// Delay dry/wet mix.
    static let delayMixRange: ClosedRange<Float> = 0.0...1.0
    /// Default 0.4: delay clearly audible without drowning the dry signal.
    static let delayMixDefault: Float = 0.4

    /// Volume range: standard 0.0 (silence) to 1.0 (unity gain).
    static let volumeRange: ClosedRange<Float> = 0.0...1.0

    /// Bit crusher depth (bits). Lower = more degradation (§4.2.2 bitcrushing).
    /// Range starts at 2: 1-bit is unusable static. Default 14 adds a subtle
    /// warmth -- every position downward introduces more audible crush.
    static let bitCrushRange: ClosedRange<Float> = 2.0...16.0
    static let bitCrushDefault: Float = 14.0

    /// Resonator MIDI note -> frequency for tunable comb filter (§5.4 Metallic Sheen).
    static let resonatorNoteRange: ClosedRange<Float> = 24.0...96.0
    static let resonatorNoteDefault: Float = 60.0  // Middle C

    /// Resonator decay factor.
    static let resonatorDecayRange: ClosedRange<Float> = 0.0...0.99
    static let resonatorDecayDefault: Float = 0.7

    /// Resonator pitch range in Hz (derived from MIDI 24-96).
    /// Used internally by SpectralProcessor for delay-length calculations.
    static let resonatorPitchRange: ClosedRange<Float> = 32.7...2093.0

    // MARK: - LFO (Stochastic Parameter Evolution)

    /// LFO rate in Hz (very slow -> moderate).
    static let lfoRateRange: ClosedRange<Float> = 0.01...10.0
    static let lfoRateDefault: Float = 0.1

    /// LFO depth: modulation amount [0..1].
    static let lfoDepthRange: ClosedRange<Float> = 0.0...1.0
    static let lfoDepthDefault: Float = 0.0

    // MARK: - Analog Filter (Moog-style Ladder)

    /// Filter cutoff frequency range (Hz). Exponential mapping in UI.
    static let filterCutoffRange: ClosedRange<Float> = 20.0...20000.0
    static let filterCutoffDefault: Float = 20000.0
    /// Filter resonance range. Self-oscillation near 0.95.
    static let filterResonanceRange: ClosedRange<Float> = 0.0...0.95
    static let filterResonanceDefault: Float = 0.0

    // MARK: - Pulse Width (Square Oscillator PWM)

    static let pulseWidthRange: ClosedRange<Float> = 0.1...0.9
    static let pulseWidthDefault: Float = 0.5

    // MARK: - Macro Controls (Curated Parameter Gestures)

    static let macroRange: ClosedRange<Float> = 0.0...1.0
    static let textureDefault: Float = 0.0
    static let chaosDefault: Float = 0.0
    static let warmthDefault: Float = 0.0

    // MARK: - Spectral Freeze

    /// When enabled, the SpectralProcessor captures and holds a spectral snapshot.
    /// Creates the "Saturation" effect described in §5.2 -- blur impulse/background.
    static let spectralFreezeBlendDefault: Float = 0.9

    // MARK: - Ring Buffer

    /// Ring buffer capacity: ~2.7 seconds at 48kHz.
    /// Sized to hold ACE-Step output without overflow (was 32768 = 682ms).
    static let ringBufferCapacity: Int = 131072

    // MARK: - Delay Line Buffer

    /// Maximum delay buffer size in samples (2s at 48kHz).
    static let maxDelaySamples: Int = 96000

    // MARK: - Performance / Motherbase (Scenes, Step Grid)

    /// Number of scenes in the bank (4 or 8).
    static let sceneCount: Int = 8
    /// Maximum crossfade duration between scenes (seconds).
    static let crossfadeMaxDuration: TimeInterval = 10.0
    /// Default crossfade duration (seconds).
    static let crossfadeDefaultDuration: TimeInterval = 2.0
    /// Number of performance steps in the grid (8 or 16).
    static let performanceStepCount: Int = 16
    /// Step advance: one step every N global iterations (when mode == iteration).
    static let stepAdvanceDivisor: Int = 1
    /// Performance view: step pad size (points).
    static let performanceStepPadSize: CGFloat = 48
    /// Performance view: grid columns for step pads.
    static let performanceStepGridColumns: Int = 8
    /// Per-step denoise strength default (1.0 = full ACE). Plan: latent noise integration.
    static let denoiseStrengthDefault: Float = 1.0
    /// Per-step denoise strength range (0 = DSP-only, 1 = full denoise).
    static let denoiseStrengthRange: ClosedRange<Float> = 0.0...1.0

    // MARK: - Sequencer v2 (Trig Types, Chain Length, Probability)

    /// Default active chain length (all 16 steps active).
    static let chainLengthDefault: Int = performanceStepCount
    /// Allowed chain length range.
    static let chainLengthRange: ClosedRange<Int> = 1...performanceStepCount
    /// Step probability range (0 = never fire, 1 = always fire).
    static let probabilityRange: ClosedRange<Float> = 0.0...1.0
    /// BPM for .time advance mode (steps per minute).
    static let stepTimeBPMDefault: Int = 120
    /// Allowed BPM range for .time advance mode.
    static let stepTimeBPMRange: ClosedRange<Int> = 30...300

    // MARK: - UI Layout

    static let windowWidth: CGFloat = 960
    static let windowHeight: CGFloat = 1240
    static let knobSize: CGFloat = 74
    static let xyPadHeight: CGFloat = 300
    static let laneStripWidth: CGFloat = 210

    // MARK: - Design System (DS)
    //
    // Centralized design tokens for typography, color, spacing, and radii.
    // All view files reference these instead of hardcoded values.
    // Zero wiring change -- purely visual consistency.

    enum DS {

        // -- Typography Scale (Fira Code) --
        // 5 levels using Fira Code for a legible, retro-terminal aesthetic.
        // Fira Code is bundled in Fonts/ and registered via ATSApplicationFontsPath.
        static let fontCaption2: CGFloat = 9    // metadata, status dots, tiny readouts
        static let fontCaption:  CGFloat = 10   // section headers, labels, bridge status
        static let fontBody:     CGFloat = 12   // primary text, lane names, buttons
        static let fontTitle:    CGFloat = 14   // view titles, popover headers
        static let fontHeadline: CGFloat = 16   // trigger button, app title

        // -- Fira Code Font Helpers --
        // Central factory methods so views never hardcode font names.
        // Falls back to system monospaced if Fira Code is unavailable.
        private static let firaCodeName = "Fira Code"

        static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            let weightSuffix: String
            switch weight {
            case .bold:     weightSuffix = "Bold"
            case .semibold: weightSuffix = "SemiBold"
            case .medium:   weightSuffix = "Medium"
            default:        weightSuffix = "Regular"
            }
            let name = "\(firaCodeName)-\(weightSuffix)"
            return Font.custom(name, size: size)
        }

        // -- Semantic Colors (CRT Phosphor Tint) --
        // Text hierarchy -- subtle green tint evokes cathode-ray phosphor.
        // Colored lane accents (red, blue, purple, etc.) still pop against
        // the tinted chrome; only the ambient UI carries the CRT feel.
        static let textPrimary   = Color.white.opacity(0.9)
        static let textSecondary = Color(red: 0.45, green: 0.55, blue: 0.45).opacity(0.7)
        static let textTertiary  = Color(red: 0.35, green: 0.45, blue: 0.35).opacity(0.5)
        static let textDisabled  = Color(red: 0.25, green: 0.35, blue: 0.25).opacity(0.3)

        // Surfaces
        static let surfacePrimary  = Color(red: 0.03, green: 0.03, blue: 0.03)
        static let surfaceElevated = Color(white: 0.06)
        static let surfaceOverlay  = Color(white: 0.08)

        // Borders (phosphor-tinted)
        static let border       = Color(red: 0.2, green: 0.3, blue: 0.2).opacity(0.3)
        static let borderActive = Color(red: 0.35, green: 0.5, blue: 0.35).opacity(0.5)

        // Functional
        static let danger  = Color.red
        static let warning = Color.orange
        static let success = Color.green
        static let info    = Color.cyan

        // Trig type colors (Sequencer v2)
        static let trigNote    = Color.red
        static let trigLock    = Color.yellow
        static let trigOneShot = Color.green
        static let trigSkip    = Color.gray

        // CRT phosphor (XY Pad aesthetic)
        static let phosphor = Color.green

        // Parameter category accents (lock indicator dots, knob accents)
        static let paramPhase     = Color.purple
        static let paramDenoise   = Color.yellow
        static let paramDelay     = Color.blue
        static let paramCrush     = Color.purple

        // -- Spacing Scale (roomier for legibility) --
        static let spacingXS:  CGFloat = 3
        static let spacingSM:  CGFloat = 6
        static let spacingMD:  CGFloat = 10
        static let spacingLG:  CGFloat = 16
        static let spacingXL:  CGFloat = 20

        // -- Corner Radii --
        static let radiusSM: CGFloat = 3
        static let radiusMD: CGFloat = 5
        static let radiusLG: CGFloat = 8

        // -- Divider (phosphor-tinted) --
        static let dividerColor = Color(red: 0.2, green: 0.3, blue: 0.2).opacity(0.3)
        static let dividerHeight: CGFloat = 1

        // -- Status Dot Sizes --
        static let dotSM: CGFloat = 6
        static let dotMD: CGFloat = 7
        static let dotLG: CGFloat = 9

        // -- Toggle / Picker defaults --
        static let toggleCornerRadius: CGFloat = 3
        static let togglePaddingH: CGFloat = 8
        static let togglePaddingV: CGFloat = 4
        static let activeOpacity: Double = 0.7
        static let inactiveOpacity: Double = 0.15

        // -- Animation --
        static let stateTransition: Animation = .easeInOut(duration: 0.15)

        // -- Accent Color Helper --
        // Single source of truth for lane accent color mapping.
        // Replaces duplicated switch-on-name logic in LaneStripView and LatentResonatorView.
        static func accentColor(for colorName: String) -> Color {
            switch colorName {
            case "red":    return .red
            case "blue":   return .blue
            case "purple": return .purple
            case "orange": return .orange
            case "cyan":   return .cyan
            case "green":  return .green
            default:       return .green
            }
        }
    }

    // MARK: - Audio Recording (Whitepaper §5 -- Emergent Phenomena Analysis)

    /// Subdirectory name within ~/Documents/ for recordings.
    static let recordingDirectoryName: String = "LatentResonator"
    /// File name prefix for all recordings.
    static let recordingFilePrefix: String = "LatentResonator_"

    // MARK: - Inference Circuit Breaker

    /// Maximum consecutive bridge failures before backing off.
    static let maxConsecutiveFailures: Int = 5
    /// Backoff duration (seconds) when the circuit breaker trips.
    static let inferenceBackoffSeconds: TimeInterval = 10.0

    // MARK: - Dispatch Queue Labels

    static let inferenceQueueLabel = "com.latentresonator.inference"
    static let audioQueueLabel = "com.latentresonator.audio"

    // MARK: - ACE-Step Bridge Server

    enum ACEBridge {
        /// Default base URL for the Python bridge server.
        static let baseURL: String = "http://127.0.0.1:8976"
        /// Health check endpoint.
        static let healthEndpoint: String = "health"
        /// Inference endpoint.
        static let inferEndpoint: String = "infer"
        /// Status endpoint.
        static let statusEndpoint: String = "status"
        /// Default port.
        static let defaultPort: Int = 8976
        /// Health polling interval in seconds.
        /// 10s reduces CPU churn during inference-heavy workloads.
        static let healthPollInterval: TimeInterval = 10.0
        /// Inference timeout in seconds.
        /// CPU-only inference takes 45-95s per diffusion step; with multi-lane concurrent
        /// requests, total wait can exceed 120s even with threaded serving. 300s safety net.
        static let inferTimeout: TimeInterval = 300.0
    }

    // MARK: - Model Configuration
    //
    // User-configurable model path with a 3-location fallback chain:
    //   1. UserDefaults override (set via Settings view)
    //   2. ~/Library/Application Support/LatentResonator/Models/ (standard macOS location)
    //   3. {projectRoot}/models/ (developer convenience)

    enum ModelConfig {
        /// Standard macOS Application Support location for model weights.
        static let appSupportModelsDir: URL = {
            guard let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                fatalError("Could not locate Application Support directory")
            }
            return base.appendingPathComponent("LatentResonator/Models")
        }()

        /// UserDefaults key for user-configured custom model path.
        static let userDefaultsKey = "customModelPath"

        /// Ensures the default Application Support models directory exists on disk.
        static func ensureDefaultDirectoryExists() {
            let fm = FileManager.default
            if !fm.fileExists(atPath: appSupportModelsDir.path) {
                try? fm.createDirectory(
                    at: appSupportModelsDir,
                    withIntermediateDirectories: true
                )
            }
        }
    }

    // MARK: - Parameter Descriptions
    // One-line hints for UI tooltips. Reduces germane cognitive load by
    // explaining what each control does without leaving the interface.

    static let parameterDescriptions: [String: String] = [
        "Guidance Scale": "CFG gain -- higher values overdrive the neural renderer, inducing hallucinations",
        "Feedback": "How much output feeds back as input for the next iteration",
        "Input Strength": "Balance between original signal structure and neural hallucination",
        "Entropy": "Stochastic noise injection into the latent space -- higher = more chaos",
        "Granularity": "Microsound window size -- lower values create granular dust",
        "Texture": "Macro: blends spectral noise, granularity, and filter resonance",
        "Chaos": "Macro: blends entropy, feedback, and guidance instability",
        "Warmth": "Macro: tilts filter cutoff low and adds saturation",
        "Filter Cutoff": "Frequency threshold for the analog-modeled filter (20-20kHz)",
        "Filter Resonance": "Emphasis at the filter cutoff frequency (0-0.95)",
        "Delay Mix": "Wet/dry balance of the Lucier-style recursive delay line",
        "Delay Time": "Delay line length in seconds (0.01-2.0s)",
        "Delay Feedback": "Amount of delay output fed back into the delay input",
        "Bit Crush Depth": "Bit resolution reduction -- lower values = harsher quantization",
        "Denoise Strength": "How much ACE denoises per step (0 = DSP-only, 100% = full neural)",
        "Shift": "ACE-Step guidance interval -- controls prompt adherence strength",
        "Steps": "Diffusion denoising steps per inference cycle (more = cleaner, slower)",
        "Volume": "Lane output level",
        "Crossfader": "Blend between Scene A and Scene B parameter states",
        "LFO Rate": "Modulation oscillator speed in Hz",
        "LFO Depth": "Modulation amount applied to the LFO target parameter",
    ]

    // MARK: - Semantic Filter Profiles
    // Maps prompt keywords to spectral emphasis curves.
    // Each profile is a [low, lowMid, highMid, high] gain vector.

    static let semanticProfiles: [String: [Float]] = [
        // Original spectral profiles
        "metallic":    [0.3, 0.5, 1.8, 2.0],   // boost highs
        "granular":    [1.0, 1.2, 1.2, 1.0],   // even with slight mid boost
        "ferrofluid":  [1.5, 0.8, 1.5, 1.8],   // liquid: boost lows + highs
        "distortion":  [1.2, 1.5, 1.5, 1.2],   // mid-heavy distortion
        "decay":       [0.5, 0.8, 1.0, 1.5],   // high-pass character
        "spectral":    [0.8, 1.0, 1.5, 1.8],   // upper frequency emphasis
        "degradation": [1.5, 1.0, 0.8, 0.5],   // low-pass character
        "bitcrushing": [1.0, 0.5, 2.0, 0.5],   // notched/harsh
        "noise":       [1.0, 1.0, 1.0, 1.0],   // flat (noise is flat)
        "resonance":   [0.5, 2.0, 2.0, 0.5],   // resonant mid peak
        "texture":     [1.0, 1.0, 1.3, 1.0],   // slight upper-mid presence
        "synthesis":   [1.0, 1.0, 1.0, 1.0],   // neutral
        "entropy":     [1.2, 0.8, 0.8, 1.2],   // scooped mids
        "saturation":  [1.5, 1.5, 0.8, 0.5],   // low-heavy saturation
        "static":      [0.5, 0.5, 1.5, 1.5],   // high-heavy static

        // Analog character profiles (Phase 8: Analog Vocabulary)
        "analog":      [1.6, 1.3, 0.9, 0.6],   // warm, heavy lows, rolled-off highs
        "vintage":     [1.5, 1.2, 0.9, 0.5],   // similar to analog, slightly softer
        "warm":        [1.4, 1.3, 1.0, 0.7],   // boosted lows and low-mids
        "fat":         [1.8, 1.4, 0.8, 0.5],   // very heavy lows
        "acid":        [0.8, 1.8, 1.5, 0.7],   // strong mid peak, scooped lows
        "squelchy":    [0.7, 1.9, 1.6, 0.6],   // resonant mid emphasis
        "buchla":      [0.9, 1.1, 1.5, 1.3],   // organic mid-high, soft lows
        "west coast":  [0.8, 1.0, 1.4, 1.4],   // complex harmonic spectrum
        "moog":        [1.8, 1.4, 0.8, 0.4],   // heavy lows, warm mids
        "minimoog":    [1.9, 1.5, 0.7, 0.3],   // deepest low emphasis
        "arp":         [0.7, 1.2, 1.5, 1.4],   // bright mids, present highs
        "sequential":  [0.8, 1.1, 1.4, 1.3],   // balanced brightness
        "roland":      [1.2, 1.2, 1.1, 0.9],   // balanced with warmth
        "juno":        [1.3, 1.2, 1.1, 0.8],   // classic Juno warmth
        "jupiter":     [1.4, 1.3, 1.0, 0.8],   // rich low-mids
        "tb303":       [0.9, 1.7, 1.4, 0.6],   // mid-focused with resonant peak
        "303":         [0.9, 1.7, 1.4, 0.6],   // alias
        "tape":        [1.3, 1.1, 0.9, 0.5],   // rolled-off highs, low boost
        "cassette":    [1.2, 1.0, 0.8, 0.4],   // duller tape character
        "transistor":  [1.1, 1.4, 1.3, 0.8],   // mid saturation character
        "tube":        [1.3, 1.3, 1.0, 0.6],   // warm, even harmonics
        "valve":       [1.3, 1.3, 1.0, 0.6],   // alias for tube
    ]
}

// MARK: - Lane Preset
//
// Encapsulates a complete parameter snapshot for one ResonatorLane.
// Four factory presets ship with the app (DRUMS, BASS, SYNTH, NOISE),
// each tuned to elicit a distinct sonic character from the ACE-Step
// base model. All presets use task="cover", thinking=false (§6.1
// circumventing the LM for deterministic control), and model=Base
// for full CFG support (white paper §4.2.1).

struct LanePreset: Identifiable {
    let id: String
    let name: String
    let prompt: String
    let accentColor: String          // SwiftUI named color for UI theming

    // ACE-Step 1.5 parameters
    let guidanceScale: Float
    let shift: Float
    let inferMethod: String          // "ode" or "sde"
    let inferenceSteps: Int
    let inputStrength: Float
    let entropyLevel: Float          // [0..100]
    let granularity: Float           // [0..100]
    let feedbackAmount: Float        // [0..1]

    // Excitation source
    let excitationMode: ExcitationMode

    // Effects chain presets
    let delayTime: Float
    let delayFeedback: Float
    let delayMix: Float
    let bitCrushDepth: Float         // bits (16 = clean)
    let resonatorNote: Float         // MIDI note (0 = off)
    let resonatorDecay: Float

    // Analog engine parameters
    let filterCutoff: Float
    let filterResonance: Float
    let filterMode: FilterMode
    let saturationMode: SaturationMode
    let pulseWidth: Float

    // Macro starting points
    let texture: Float
    let chaos: Float
    let warmth: Float

    // Per-lane prompt evolution chain (White Paper §4.2.2)
    //
    // Each lane defines its own 3-phase prompt trajectory, tuned to
    // its sonic role. This realizes the "Recursive Drift" mechanism:
    // the prompt shifts across iterations to steer toward entropy
    // maximization within each lane's unique timbral domain.
    let promptPhase1: String    // iterations 0-2: initial texturization
    let promptPhase2: String    // iterations 3-8: recursive drift
    let promptPhase3: String    // iterations 9+:  deep saturation
}

// MARK: - Factory Presets (Analog Personality Engine)
//
// Presets designed around classic analog synth character, each tuned
// to elicit a distinct sonic personality through ACE-Step inference.
// Together they form a complete live performance palette spanning
// the vocabulary of 50s-80s analog synthesis:
//   MOOG BASS    -- deep, round, subtractive (Minimoog 1970)
//   ARP LEAD     -- cutting, vocal, PWM-driven (ARP 2600 1971)
//   BUCHLA PERC  -- organic, plucky, West Coast (Buchla 200 1964)
//   ROLAND PAD   -- lush, atmospheric, drifting (Juno-60 1982)
//   TB-303 ACID  -- squelchy, resonant, the acid sound (Roland 1981)
//   NOISE SCAPE  -- experimental, pure AI hallucination, entropic

extension LanePreset {

    /// MOOG BASS -- Deep, round, the 70s bass. Saw oscillator through
    /// lowpass filter at 200Hz with tube saturation. The Minimoog sound.
    static let moogBass = LanePreset(
        id: "moog_bass",
        name: "MOOG BASS",
        prompt: "deep analog bass, warm sub, minimoog, fat low end, vintage synthesizer",
        accentColor: "blue",
        guidanceScale: 10.0,
        shift: 4.0,
        inferMethod: "sde",
        inferenceSteps: 8,
        inputStrength: 0.65,
        entropyLevel: 15.0,
        granularity: 10.0,
        feedbackAmount: 0.55,
        excitationMode: .sawOsc,
        delayTime: 0.5,
        delayFeedback: 0.4,
        delayMix: 0.2,
        bitCrushDepth: 16.0,
        resonatorNote: 28.0,
        resonatorDecay: 0.8,
        filterCutoff: 200.0,
        filterResonance: 0.4,
        filterMode: .lowpass,
        saturationMode: .tube,
        pulseWidth: 0.5,
        texture: 0.3,
        chaos: 0.2,
        warmth: 0.7,
        promptPhase1: "deep analog bass, warm sub, minimoog, fat low end, vintage synthesizer",
        promptPhase2: "analog decay artifacts, saturated sub-harmonics, moog filter sweep, warm tape bass",
        promptPhase3: "sub-frequency dissolution, infrasonic rumble, vintage bass saturation, analog entropy"
    )

    /// ARP LEAD -- Cutting, vocal, PWM-driven. Square oscillator with
    /// bandpass filter sweep and transistor saturation. The ARP 2600 sound.
    static let arpLead = LanePreset(
        id: "arp_lead",
        name: "ARP LEAD",
        prompt: "bright analog lead, arp synthesizer, cutting, sequential circuits, sharp attack",
        accentColor: "cyan",
        guidanceScale: 12.0,
        shift: 5.0,
        inferMethod: "ode",
        inferenceSteps: 8,
        inputStrength: 0.50,
        entropyLevel: 25.0,
        granularity: 20.0,
        feedbackAmount: 0.45,
        excitationMode: .squareOsc,
        delayTime: 0.15,
        delayFeedback: 0.5,
        delayMix: 0.35,
        bitCrushDepth: 14.0,
        resonatorNote: 60.0,
        resonatorDecay: 0.6,
        filterCutoff: 3000.0,
        filterResonance: 0.5,
        filterMode: .bandpass,
        saturationMode: .transistor,
        pulseWidth: 0.35,
        texture: 0.4,
        chaos: 0.3,
        warmth: 0.4,
        promptPhase1: "bright analog lead, arp synthesizer, cutting, sequential circuits, sharp attack",
        promptPhase2: "analog lead decay, filter sweep, PWM modulation, resonant peak drift",
        promptPhase3: "dissolved lead fragments, spectral lead saturation, broken analog circuit"
    )

    /// BUCHLA PERC -- Organic, plucky, West Coast synthesis. Koenig Seed
    /// excitation through highpass filter with diode saturation.
    static let buchlaPerc = LanePreset(
        id: "buchla_perc",
        name: "BUCHLA PERC",
        prompt: "percussive organic pluck, buchla, metallic, west coast synthesis, complex waveform",
        accentColor: "red",
        guidanceScale: 13.0,
        shift: 3.0,
        inferMethod: "ode",
        inferenceSteps: 8,
        inputStrength: 0.55,
        entropyLevel: 30.0,
        granularity: 35.0,
        feedbackAmount: 0.40,
        excitationMode: .koenigSeed,
        delayTime: 0.125,
        delayFeedback: 0.45,
        delayMix: 0.3,
        bitCrushDepth: 10.0,
        resonatorNote: 48.0,
        resonatorDecay: 0.5,
        filterCutoff: 800.0,
        filterResonance: 0.3,
        filterMode: .highpass,
        saturationMode: .diode,
        pulseWidth: 0.5,
        texture: 0.5,
        chaos: 0.4,
        warmth: 0.3,
        promptPhase1: "percussive organic pluck, buchla, metallic, west coast synthesis, complex waveform",
        promptPhase2: "industrial degradation, mechanical rhythm, fragmented percussion, metallic decay",
        promptPhase3: "granular rhythmic dust, scattered impulses, stochastic percussion, broken machinery"
    )

    /// ROLAND PAD -- Lush, atmospheric, drifting. Triangle oscillator
    /// through lowpass filter with tube saturation and long delay.
    static let rolandPad = LanePreset(
        id: "roland_pad",
        name: "ROLAND PAD",
        prompt: "ambient analog pad, lush strings, warm drift, juno chorus, vintage atmosphere",
        accentColor: "purple",
        guidanceScale: 10.0,
        shift: 6.0,
        inferMethod: "sde",
        inferenceSteps: 8,
        inputStrength: 0.60,
        entropyLevel: 20.0,
        granularity: 15.0,
        feedbackAmount: 0.55,
        excitationMode: .triangleOsc,
        delayTime: 0.75,
        delayFeedback: 0.6,
        delayMix: 0.45,
        bitCrushDepth: 16.0,
        resonatorNote: 64.0,
        resonatorDecay: 0.75,
        filterCutoff: 5000.0,
        filterResonance: 0.2,
        filterMode: .lowpass,
        saturationMode: .tube,
        pulseWidth: 0.5,
        texture: 0.25,
        chaos: 0.2,
        warmth: 0.6,
        promptPhase1: "ambient analog pad, lush strings, warm drift, juno chorus, vintage atmosphere",
        promptPhase2: "evolving pad texture, spectral drift, analog warmth, tape saturation, slow morph",
        promptPhase3: "dissolved pad mass, spectral blur, formless analog warmth, infinite sustain"
    )

    /// TB-303 ACID -- THE acid sound. Saw oscillator through lowpass
    /// filter with high resonance and transistor saturation.
    static let tb303Acid = LanePreset(
        id: "tb303_acid",
        name: "TB-303 ACID",
        prompt: "acid bass, squelchy resonance, 303 machine, analog acid line, resonant filter",
        accentColor: "green",
        guidanceScale: 14.0,
        shift: 4.0,
        inferMethod: "ode",
        inferenceSteps: 8,
        inputStrength: 0.50,
        entropyLevel: 20.0,
        granularity: 25.0,
        feedbackAmount: 0.50,
        excitationMode: .sawOsc,
        delayTime: 0.166,
        delayFeedback: 0.55,
        delayMix: 0.3,
        bitCrushDepth: 14.0,
        resonatorNote: 36.0,
        resonatorDecay: 0.65,
        filterCutoff: 500.0,
        filterResonance: 0.85,
        filterMode: .lowpass,
        saturationMode: .transistor,
        pulseWidth: 0.5,
        texture: 0.5,
        chaos: 0.3,
        warmth: 0.5,
        promptPhase1: "acid bass, squelchy resonance, 303 machine, analog acid line, resonant filter",
        promptPhase2: "acid line mutation, filter squelch, resonant peak, distorted bass pattern",
        promptPhase3: "dissolved acid mass, 303 entropy, resonant noise, analog circuit overload"
    )

    /// NOISE SCAPE -- Experimental. Silence excitation forces pure AI
    /// hallucination. Full chaos, heavy texture. The "deep saturation"
    /// endpoint described in §4.2.2 Phase 3.
    static let noiseScape = LanePreset(
        id: "noise_scape",
        name: "NOISE SCAPE",
        prompt: "abstract noise texture, granular entropy, digital decay, spectral mass, stochastic cloud",
        accentColor: "orange",
        guidanceScale: 16.0,
        shift: 9.0,
        inferMethod: "sde",
        inferenceSteps: 8,
        inputStrength: 0.35,
        entropyLevel: 60.0,
        granularity: 70.0,
        feedbackAmount: 0.7,
        excitationMode: .silence,
        delayTime: 1.0,
        delayFeedback: 0.7,
        delayMix: 0.5,
        bitCrushDepth: 4.0,
        resonatorNote: 0.0,
        resonatorDecay: 0.0,
        filterCutoff: 20000.0,
        filterResonance: 0.0,
        filterMode: .lowpass,
        saturationMode: .clean,
        pulseWidth: 0.5,
        texture: 0.8,
        chaos: 0.9,
        warmth: 0.2,
        promptPhase1: "abstract noise texture, granular entropy, digital decay, spectral mass, stochastic cloud",
        promptPhase2: "static dissolution, white noise degradation, spectral erosion, entropic decay, formless hiss",
        promptPhase3: "white noise saturation, complete entropy, stochastic cloud, total spectral mass, heat death signal"
    )

    /// All factory presets in display order.
    static let allPresets: [LanePreset] = [
        .moogBass, .arpLead, .buchlaPerc,
        .rolandPad, .tb303Acid, .noiseScape
    ]
}
