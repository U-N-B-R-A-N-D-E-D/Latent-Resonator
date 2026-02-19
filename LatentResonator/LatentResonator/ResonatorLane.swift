import Foundation
import AVFoundation
import Combine
import Accelerate

// MARK: - Resonator Lane (Whitepaper ?3.3, ?4.2.2, ?6.1)
//
// Self-contained feedback loop encapsulating one independent
// Latent Resonator channel. Each lane owns its complete signal
// chain: excitation + feedback -> DSP -> capture -> inference -> loop.
//
// Architecture: single combined source node with dual-speed processing.
//   REAL-TIME PATH (immediate, <5ms):
//     combinedSourceNode generates excitation, mixes with feedback,
//     runs SpectralProcessor + Delay Line. ALL DSP controls respond
//     instantly to knob movement on BOTH excitation and feedback.
//   INFERENCE PATH (slow, 2-30s):
//     laneMixer tap -> captureBuffer -> ACE-Step / CoreML -> feedbackBuffer
//     AI model processes audio in the background.
//
// Signal flow (per lane):
//
//   combinedSourceNode:
//     [excitation + feedback*gain] -> SpectralProcessor -> Delay
//         |
//         v
//     laneMixer -> masterMixer -> output
//         |
//     capture tap -> captureBuffer -> inferenceTask
//                                        |
//                          ACE / CoreML / passthrough
//                                        |
//                                  feedbackBuffer (loops back)
//
// White paper reference:
//   S_{i+1} = ACE(S_i + N(u,o), P, y)  (section 3.3)
//   The model as "Black Box Resonator"  (section 6.1)
//   The Lucier Chamber (delay)          (section 1.2)

// MARK: - Spectral Feature Snapshot (Telemetry)
//
// Lightweight record of spectral features at one point in time.
// Appended to a per-lane log after each inference cycle. Exported
// alongside recorded audio for post-performance analysis.

struct SpectralFeatureSnapshot: Codable {
    let iteration: Int
    let centroid: Float
    let flatness: Float
    let flux: Float
    let promptPhase: Int
    let inputStrength: Float
    let timestamp: TimeInterval
}

// MARK: - Cycle Parameter Snapshot
//
// Thread-safe snapshot of all parameters needed for one inference cycle.
// Captured on the MainActor (via DispatchQueue.main) before each cycle
// begins, preventing torn reads of @Published properties from the
// background inference Task. All fields are value types -> Sendable.

struct CycleParameters: Sendable {
    let name: String
    let cfg: Float
    let entropy: Float           // normalized [0..1]
    let grain: Float             // normalized [0..1]
    let strength: Float
    let feedback: Float
    let freeze: Bool
    let crush: Float
    let resonatorNote: Float
    let shift: Float
    let inferMethod: String
    let steps: Int
    let prompt: String
    let lfoRate: Float
    let lfoDepth: Float
    let lfoTarget: LFOTarget
    let denoiseStrength: Float   // 0 = DSP-only, 1 = full ACE (per-step lock)
}

final class ResonatorLane: ObservableObject, Identifiable {

    // (audio-thread debug counters removed -- file I/O on RT thread causes overload)

    // MARK: - Identity

    let id: UUID
    @Published var name: String
    let accentColorName: String

    // MARK: - Mixer State

    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var isSoloed: Bool = false

    // MARK: - Step Grid (Per-Lane, Focus Lane UX)
    //
    // Each lane has its own step sequence and parameter locks. The UI shows
    // only the focused lane's grid (Elektron-style). Enables polirhythm
    // (different chain lengths) and independent voice modulation.
    @Published var stepGrid: StepGrid = StepGrid()

    // MARK: - ACE-Step 1.5 Parameters (Per-Lane)

    @Published var guidanceScale: Float
    @Published var shift: Float
    @Published var inputStrength: Float
    @Published var entropyLevel: Float       // [0..100]
    @Published var granularity: Float        // [0..100]
    @Published var inferMethod: String       // "ode" or "sde"
    @Published var inferenceSteps: Int
    @Published var feedbackAmount: Float

    // MARK: - Auto Decay (White Paper ?4.2.2 -- Recursive Drift Trajectory)

    /// When enabled, inputStrength interpolates from its captured origin
    /// toward autoDecayTarget over autoDecayIterations. Single toggle;
    /// target and rate are preset-level configuration (not live knobs).
    @Published var autoDecayEnabled: Bool = false {
        didSet {
            if autoDecayEnabled && !oldValue {
                autoDecayOrigin = inputStrength
            }
        }
    }
    /// Preset-defined endpoint for inputStrength decay.
    var autoDecayTarget: Float = LRConstants.autoDecayTargetDefault
    /// Preset-defined number of iterations to reach the target.
    var autoDecayIterations: Float = LRConstants.autoDecayIterationsDefault
    /// Captured inputStrength at the moment auto-decay was enabled / inference started.
    private var autoDecayOrigin: Float = LRConstants.inputStrengthDefault

    // MARK: - Audio Input (Shared Buffer for .audioInput Excitation)

    /// Shared ring buffer written by NeuralEngine's hardware input tap.
    /// Lanes with excitationMode == .audioInput read from this.
    weak var audioInputBuffer: CircularAudioBuffer?

    // MARK: - Cross-Lane Feedback

    /// When set, this lane's feedback path reads from another lane's
    /// feedbackBuffer instead of its own. nil = self-feedback (default).
    @Published var feedbackSourceLaneId: UUID?
    /// External feedback ring buffer (set by NeuralEngine.updateFeedbackRouting()).
    weak var externalFeedbackBuffer: CircularAudioBuffer?

    // MARK: - Prompt (Per-Lane)

    @Published var promptText: String
    @Published var promptEvolutionEnabled: Bool = true

    /// Per-lane prompt evolution phases (?4.2.2 Recursive Drift).
    /// Each lane evolves through its own unique timbral trajectory.
    private var promptPhases: [String]

    /// The currently active prompt phase, conditioned on spectral flatness.
    /// Phase transitions are driven by the signal's entropic state:
    ///   Phase 1: tonal/structured (flatness < phase2Threshold)
    ///   Phase 2: entropic drift (flatness >= phase2Threshold and < phase3Threshold)
    ///   Phase 3: deep saturation (flatness >= phase3Threshold)
    /// Falls back to iteration-count heuristic for the first 2 iterations
    /// when spectral features have not yet stabilized.
    var currentPromptPhase: Int {
        if iterationCount < 2 { return 1 }
        let flat = spectralFlatnessNormalized
        if flat >= LRConstants.spectralPhase3Threshold { return 3 }
        if flat >= LRConstants.spectralPhase2Threshold { return 2 }
        return 1
    }

    /// Latest spectral centroid from the DSP chain [0..1]. Published for UI visualization.
    @Published var spectralCentroidNormalized: Float = 0.0
    /// Latest spectral flatness from the DSP chain [0..1]. Published for UI visualization.
    @Published var spectralFlatnessNormalized: Float = 0.0

    /// When set (1, 2, or 3), overrides currentPromptPhase for resolveActivePrompt (?4.2.2 step lock).
    @Published var promptPhaseOverride: Int? = nil

    // MARK: - Iteration Archive (Selective Recall)

    /// Ring buffer of past iteration audio. Newest at the end.
    /// Max size: LRConstants.iterationArchiveSize.
    private(set) var iterationArchive: [[Float]] = []

    /// When set, the lane replays archived audio from this index instead
    /// of the normal loop buffer. nil = normal playback.
    @Published var archiveRecallIndex: Int? = nil

    // MARK: - Spectral Feature Log (Telemetry)

    /// Running log of spectral features captured after each inference cycle.
    /// Capped at featureLogMaxEntries. Exported with audio recordings.
    private(set) var featureLog: [SpectralFeatureSnapshot] = []

    /// When true, next inference cycle skips ACE/CoreML and passes through (trigless / DSP-only step).
    var dspOnlyForNextCycle: Bool = false

    /// Per-step denoise strength for next inference (0 = DSP-only, 1 = full ACE). Set by engine from step grid.
    var denoiseStrengthForInference: Float = LRConstants.denoiseStrengthDefault
    /// Per-lane denoise default when current step has no denoise lock. Restored from scene snapshot.
    var denoiseStrengthDefault: Float = LRConstants.denoiseStrengthDefault

    // MARK: - Excitation Source

    @Published var excitationMode: ExcitationMode
    @Published var sineFrequency: Float = LRConstants.sineFrequencyDefault
    @Published var pulseDensity: Float = LRConstants.pulseDensityDefault
    @Published var euclideanPulses: Int = LRConstants.euclideanPulses
    @Published var euclideanSteps: Int = LRConstants.euclideanSteps

    // MARK: - Analog Engine (Phase 3-4: Filter + Waveshaping)

    @Published var filterCutoff: Float = LRConstants.filterCutoffDefault
    @Published var filterResonance: Float = LRConstants.filterResonanceDefault
    @Published var filterMode: FilterMode = .lowpass
    @Published var saturationMode: SaturationMode = .clean
    /// Continuous crossfade [0..1] toward the next saturation mode.
    /// Driven by the WARMTH macro to eliminate discrete mode-switch clicks.
    @Published var saturationMorph: Float = 0.0
    @Published var pulseWidth: Float = LRConstants.pulseWidthDefault

    // MARK: - Macro Controls (Phase 5: Musical Gestures)
    //
    // Three macros that map to multiple parameters with curated curves.
    // TEXTURE: clean/pure -> complex/rich
    // CHAOS: AI-stable -> AI-wild
    // WARMTH: cold digital -> warm analog
    //
    // Performance: during continuous XY Pad drag, suppressMacroApplication
    // is set to true so that the 5-8 downstream @Published writes (filter,
    // entropy, cfg, etc.) only fire at the pad's throttled commit rate
    // (~20 Hz) instead of at display rate (~60 Hz). The XY Pad calls
    // applyMacroTexture()/applyMacroChaos() explicitly on each commit tick
    // and on drag end.

    /// When true, texture/chaos/warmth didSet skips applyMacro calls.
    /// Set by XY Pad (or any continuous controller) during drag to batch
    /// updates and avoid cascading 10+ objectWillChange notifications per
    /// display frame.
    var suppressMacroApplication: Bool = false

    @Published var texture: Float = LRConstants.textureDefault {
        didSet {
            guard !suppressMacroApplication else { return }
            DispatchQueue.main.async { [weak self] in self?.applyMacroTexture() }
        }
    }
    @Published var chaos: Float = LRConstants.chaosDefault {
        didSet {
            guard !suppressMacroApplication else { return }
            DispatchQueue.main.async { [weak self] in self?.applyMacroChaos() }
        }
    }
    @Published var warmth: Float = LRConstants.warmthDefault {
        didSet {
            guard !suppressMacroApplication else { return }
            DispatchQueue.main.async { [weak self] in self?.applyMacroWarmth() }
        }
    }

    // MARK: - Effects Chain

    @Published var delayTime: Float
    @Published var delayFeedback: Float
    @Published var delayMix: Float
    @Published var bitCrushDepth: Float
    @Published var resonatorNote: Float
    @Published var resonatorDecay: Float
    @Published var spectralFreezeActive: Bool = false

    // MARK: - LFO (Per-Lane Stochastic Evolution)

    @Published var lfoRate: Float = LRConstants.lfoRateDefault
    @Published var lfoDepth: Float = LRConstants.lfoDepthDefault
    @Published var lfoTarget: LFOTarget = .none

    /// Real-time LFO phase -- ticked inside the audio render callback
    /// so that feedback/resonator modulation runs at buffer rate (~5ms).
    /// Separate from SignalGenerator.lfoPhase to avoid thread contention.
    private var rtLfoPhase: Double = 0.0

    // MARK: - Per-Lane Recording (?5 -- Emergent Phenomena Analysis)

    /// Per-lane recorder -- captures isolated output for studying
    /// one latent trajectory in isolation (?5.1-5.4).
    let laneRecorder = AudioRecorder()
    @Published var isLaneRecording: Bool = false

    // MARK: - Status

    @Published var iterationCount: Int = 0
    @Published var currentRMS: Float = 0.0
    @Published var isRunning: Bool = false
    @Published var isInferring: Bool = false

    /// FFT magnitude bins for spectral visualization (~10 Hz update rate).
    /// Size: fftSize/2 (512 bins at 1024 FFT). Empty when not processing.
    @Published var spectralBins: [Float] = []

    /// Throttle RMS UI updates to ~15 Hz instead of every audio buffer (~100 Hz).
    /// Reduces LaneStripView re-renders during playback without losing visual fidelity.
    private var lastRMSDispatchTime: UInt64 = 0
    private var lastSpectralDispatchTime: UInt64 = 0

    // MARK: - Audio Graph Nodes (Managed by NeuralEngine)

    /// These are created and connected by NeuralEngine.rebuildAudioGraph().
    /// The lane itself provides render callbacks but does not own the graph.
    var combinedSourceNode: AVAudioSourceNode!
    let laneMixer = AVAudioMixerNode()
    /// Tracks whether a capture tap is installed. Prevents double removeTap (malloc double free).
    private var captureTapInstalled: Bool = false

    // MARK: - Ring Buffers

    let captureBuffer = CircularAudioBuffer(capacity: LRConstants.ringBufferCapacity)
    let feedbackBuffer = CircularAudioBuffer(capacity: LRConstants.ringBufferCapacity)

    // MARK: - Pre-allocated Audio Thread Buffer

    private let feedbackReadBuffer: UnsafeMutablePointer<Float>
    private let excitationReadBuffer: UnsafeMutablePointer<Float>
    private let audioReadCapacity = 8192


    // MARK: - Inference Loop Buffer (Sustain Between Cycles)
    //
    // ACE inference takes ~20s but produces only 1s of audio. Without
    // looping, the feedback path is silent 95% of the time and DSP knobs
    // have nothing to process. This buffer stores the last inference output
    // and replays it continuously when the ring buffer drains.
    //
    // Thread safety: loopBuffer is a fixed-size UnsafeMutablePointer
    // written by the inference thread and read by the audio thread.
    // loopSampleCount is an Int (64-bit atomic on Apple Silicon).
    // A torn read of a single Float during the copy is inaudible.

    private let loopBuffer: UnsafeMutablePointer<Float>
    private let loopCapacity: Int = LRConstants.bufferSize
    /// Number of valid samples in the loop buffer. Written by inference, read by audio thread.
    private var loopSampleCount: Int = 0
    /// Current read position in the loop (audio thread only).
    private var loopReadPos: Int = 0

    // MARK: - Signal Generator

    let signalGenerator = SignalGenerator()

    // MARK: - DSP Spectral Processor (Black Box Resonator ?6.1)

    let spectralProcessor = SpectralProcessor(sampleRate: LRConstants.sampleRate)

    // MARK: - Excitation Path DSP State (Filter + Saturation)
    //
    // The same ladder filter and waveshaper applied in the feedback path
    // (via SpectralProcessor) is also applied to the excitation signal
    // so sliders like filterCutoff, saturationMode, and texture instantly
    // colour the oscillator -- no AI audio needed to "feel" the controls.

    // Ladder filter state removed -- inline excitation DSP was producing NaN.
    // Filtering is handled by SpectralProcessor in the feedback path.

    // MARK: - Delay Line (The Lucier Chamber -- ?1.2)

    private var delayLineBuffer: [Float]
    private var delayWritePos: Int = 0

    // MARK: - Inference

    /// Structured concurrency task running the recursive inference loop.
    /// Replaces the DispatchQueue + DispatchSemaphore pattern to eliminate
    /// the deadlock-prone Semaphore+Task antipattern.
    private var inferenceTask: Task<Void, Never>?

    /// Consecutive bridge failures for circuit-breaker logic.
    /// After `LRConstants.maxConsecutiveFailures` consecutive errors,
    /// the lane backs off before retrying.
    private var consecutiveFailures: Int = 0

    /// Weak reference to the shared bridge -- NeuralEngine owns the bridge.
    weak var bridge: ACEStepBridge?

    /// Weak reference to the shared CoreMLInference -- NeuralEngine owns it.
    weak var coreMLInference: CoreMLInference?

    // MARK: - Processing Format

    private var processingFormat: AVAudioFormat!

    // MARK: - Initialization

    /// Create a lane from a preset configuration.
    ///
    /// - Parameters:
    ///   - preset: Factory or user-defined parameter snapshot.
    ///   - bridge: Shared ACEStepBridge (owned by NeuralEngine).
    init(preset: LanePreset, bridge: ACEStepBridge? = nil) {
        self.id = UUID()
        self.name = preset.name
        self.accentColorName = preset.accentColor
        self.bridge = bridge

        // ACE-Step parameters from preset
        self.guidanceScale = preset.guidanceScale
        self.shift = preset.shift
        self.inputStrength = preset.inputStrength
        self.entropyLevel = preset.entropyLevel
        self.granularity = preset.granularity
        self.inferMethod = preset.inferMethod
        self.inferenceSteps = preset.inferenceSteps
        self.feedbackAmount = preset.feedbackAmount
        self.autoDecayTarget = preset.autoDecayTarget
        self.autoDecayIterations = preset.autoDecayIterations
        self.promptText = preset.prompt
        self.promptPhases = [preset.promptPhase1, preset.promptPhase2, preset.promptPhase3]
        self.excitationMode = preset.excitationMode

        // Effects chain from preset
        self.delayTime = preset.delayTime
        self.delayFeedback = preset.delayFeedback
        self.delayMix = preset.delayMix
        self.bitCrushDepth = preset.bitCrushDepth
        self.resonatorNote = preset.resonatorNote
        self.resonatorDecay = preset.resonatorDecay

        // Analog engine from preset
        self.filterCutoff = preset.filterCutoff
        self.filterResonance = preset.filterResonance
        self.filterMode = preset.filterMode
        self.saturationMode = preset.saturationMode
        self.pulseWidth = preset.pulseWidth

        // Macro starting points from preset
        self.texture = preset.texture
        self.chaos = preset.chaos
        self.warmth = preset.warmth

        // Allocate buffers
        self.delayLineBuffer = [Float](repeating: 0, count: LRConstants.maxDelaySamples)
        self.feedbackReadBuffer = .allocate(capacity: audioReadCapacity)
        self.feedbackReadBuffer.initialize(repeating: 0.0, count: audioReadCapacity)
        self.excitationReadBuffer = .allocate(capacity: audioReadCapacity)
        self.excitationReadBuffer.initialize(repeating: 0.0, count: audioReadCapacity)
        self.loopBuffer = .allocate(capacity: loopCapacity)
        self.loopBuffer.initialize(repeating: 0.0, count: loopCapacity)

        setupProcessingFormat()
        spectralProcessor.reconfigure(fftSize: preset.fftSize)
        setupCombinedSourceNode()
    }

    deinit {
        inferenceTask?.cancel()
        feedbackReadBuffer.deinitialize(count: audioReadCapacity)
        feedbackReadBuffer.deallocate()
        excitationReadBuffer.deinitialize(count: audioReadCapacity)
        excitationReadBuffer.deallocate()
        loopBuffer.deinitialize(count: loopCapacity)
        loopBuffer.deallocate()
    }

    // MARK: - Audio Node Setup

    private func setupProcessingFormat() {
        processingFormat = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )
    }



    private func setupCombinedSourceNode() {
        let sigGen = signalGenerator
        let sr = LRConstants.sampleRate
        let readCap = audioReadCapacity
        let readBuf = feedbackReadBuffer
        let excBuf = excitationReadBuffer
        let fbBuffer = feedbackBuffer
        let processor = spectralProcessor

        combinedSourceNode = AVAudioSourceNode(
            format: processingFormat
        ) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = min(Int(frameCount), readCap)

            // Skip rendering for muted/inactive slots to save CPU.
            if self.isMuted {
                for buf in ablPointer {
                    if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
                }
                return noErr
            }

            // -- 1. GENERATE EXCITATION (mono) --
            if self.excitationMode == .audioInput, let aiBuf = self.audioInputBuffer {
                let got = aiBuf.read(into: excBuf, count: count)
                if got < count {
                    memset(excBuf.advanced(by: got), 0,
                           (count - got) * MemoryLayout<Float>.size)
                }
            } else {
                sigGen.sineFrequency = self.sineFrequency
                sigGen.pulseDensity = self.pulseDensity
                sigGen.euclideanPulses = self.euclideanPulses
                sigGen.euclideanSteps = self.euclideanSteps
                sigGen.pulseWidth = self.pulseWidth
                sigGen.renderInto(left: excBuf, right: excBuf,
                                  frameCount: count, mode: self.excitationMode,
                                  sampleRate: sr)
            }

            // -- 2. READ FEEDBACK from ring buffer + loop/archive fallback --
            // Cross-lane feedback: if an external source is wired, read from it.
            let activeFeedback = self.externalFeedbackBuffer ?? fbBuffer
            let readCount = activeFeedback.read(into: readBuf, count: count)
            if readCount < count {
                // Archive recall: replay a specific past iteration buffer.
                let archive = self.iterationArchive
                if let recallIdx = self.archiveRecallIndex,
                   recallIdx >= 0, recallIdx < archive.count, !archive[recallIdx].isEmpty {
                    let arc = archive[recallIdx]
                    let arcLen = arc.count
                    for i in readCount..<count {
                        readBuf[i] = arc[self.loopReadPos % arcLen]
                        self.loopReadPos = (self.loopReadPos + 1) % arcLen
                    }
                } else {
                    let loopLen = self.loopSampleCount
                    if loopLen > 0 {
                        for i in readCount..<count {
                            readBuf[i] = self.loopBuffer[self.loopReadPos]
                            self.loopReadPos = (self.loopReadPos + 1) % loopLen
                        }
                    } else {
                        memset(readBuf.advanced(by: readCount), 0,
                               (count - readCount) * MemoryLayout<Float>.size)
                    }
                }
            }

            // -- 3. MIX: excitation + feedback * gain -> mono --
            let fbGain = self.feedbackAmount
            var mono = [Float](repeating: 0.0, count: count)
            // mono[i] = excitation[i] + feedback[i] * feedbackAmount
            for i in 0..<count {
                mono[i] = excBuf[i] + readBuf[i] * fbGain
            }

            // -- 4. READ DSP PARAMETERS --
            var cfg = self.guidanceScale
            var entropy = self.entropyLevel / 100.0
            var grain = self.granularity / 100.0
            var fb = self.feedbackAmount
            let freeze = self.spectralFreezeActive
            let crushBits = self.bitCrushDepth
            let crush = max(0.0, 1.0 - (crushBits - 1.0) / 15.0)
            let resNote = self.resonatorNote
            var resPitch: Float = resNote > 0
                ? 440.0 * powf(2.0, (resNote - 69.0) / 12.0) : 0.0
            let resDecay = self.resonatorDecay

            // 4a. REAL-TIME LFO -- modulates all targets at buffer rate
            let lfoTarget = self.lfoTarget
            let lfoDepth = self.lfoDepth
            let lfoRate = self.lfoRate
            if lfoTarget != .none, lfoDepth > 0.001, lfoRate > 0.001 {
                let phaseInc = 2.0 * Double.pi * Double(lfoRate)
                                * Double(count) / LRConstants.sampleRate
                self.rtLfoPhase += phaseInc
                if self.rtLfoPhase >= 2.0 * Double.pi {
                    self.rtLfoPhase -= 2.0 * Double.pi
                }
                let lfoVal = Float(sin(self.rtLfoPhase)) * lfoDepth
                switch lfoTarget {
                case .none: break
                case .feedback:
                    fb = min(max(fb + lfoVal * 0.3, 0.0), 1.0)
                case .resonator:
                    let rng = LRConstants.resonatorPitchRange
                    resPitch = min(max(resPitch + lfoVal * 200.0,
                                       rng.lowerBound), rng.upperBound)
                case .entropy:
                    entropy = min(max(entropy + lfoVal * 0.5, 0.0), 1.0)
                case .granularity:
                    grain = min(max(grain + lfoVal * 0.5, 0.0), 1.0)
                case .guidance:
                    let rng = LRConstants.cfgScaleRange
                    cfg = min(max(cfg + lfoVal * 3.0, rng.lowerBound), rng.upperBound)
                }
            }

            let fCutoff = self.filterCutoff
            let fResonance = self.filterResonance
            let fMode = self.filterMode
            let satMode = self.saturationMode
            let satMorph = self.saturationMorph

            // -- 5. SPECTRAL PROCESSOR + DSP CHAIN --
            let processed = processor.process(
                samples: mono,
                guidanceScale: cfg,
                entropyLevel: entropy,
                granularity: grain,
                feedbackAmount: fb,
                freezeActive: freeze,
                bitCrushDepth: crush,
                resonatorPitch: resPitch,
                resonatorDecay: resDecay,
                filterCutoff: fCutoff,
                filterResonance: fResonance,
                filterMode: fMode,
                saturationMode: satMode,
                saturationMorph: satMorph
            )

            // -- 6. DELAY LINE --
            var output = processed
            self.applyDelayLine(&output)

            // -- 7. NaN/Inf safety net --
            for i in 0..<output.count {
                if output[i].isNaN || output[i].isInfinite {
                    output[i] = 0.0
                }
            }

            // -- 8. Write to all output channels --
            for bufferIdx in 0..<ablPointer.count {
                guard let data = ablPointer[bufferIdx].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                for i in 0..<count {
                    data[i] = i < output.count ? output[i] : 0.0
                }
            }

            return noErr
        }
    }

    /// Install the tap on laneMixer to capture audio for inference + RMS metering.
    /// Called by NeuralEngine after connecting nodes.
    func installCaptureTap() {
        guard !captureTapInstalled else { return }
        laneMixer.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(LRConstants.bufferSize),
            format: processingFormat
        ) { [weak self] buffer, _ in
            self?.processAudioTap(buffer)
        }
        captureTapInstalled = true
    }

    /// Remove the capture tap. Called before detaching nodes.
    /// Guarded to prevent double removeTap (causes malloc double free).
    func removeCaptureTap() {
        guard captureTapInstalled else { return }
        laneMixer.removeTap(onBus: 0)
        captureTapInstalled = false
    }

    // MARK: - Audio Tap (Runs on Audio Thread)

    private func processAudioTap(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)

        // Per-lane recording -- append buffer if active
        laneRecorder.writeBuffer(buffer)

        let leftChannel = channelData[0]
        let rightChannel = buffer.format.channelCount > 1 ? channelData[1] : channelData[0]

        // Mix L+R to mono for inference pipeline
        var monoMix = [Float](repeating: 0.0, count: frameCount)
        var half: Float = 0.5
        vDSP_vasm(leftChannel, 1, rightChannel, 1, &half, &monoMix, 1, vDSP_Length(frameCount))
        captureBuffer.write(monoMix)

        // RMS for UI metering -- throttled to ~15 Hz to reduce view re-renders.
        // mach_absolute_time() is safe on the audio thread (no allocations).
        var rms: Float = 0
        vDSP_rmsqv(leftChannel, 1, &rms, vDSP_Length(frameCount))

        let now = mach_absolute_time()
        let elapsedNs = now - lastRMSDispatchTime
        if elapsedNs > 66_000_000 {  // ~66ms = ~15 Hz
            lastRMSDispatchTime = now
            DispatchQueue.main.async { [weak self] in
                self?.currentRMS = rms
            }
        }

        // Spectral bins + centroid/flatness for CNT/FLAT drift pad -- throttled to ~15 Hz
        // When muted, render returns early so spectralProcessor is never updated; use center (0.5) as "no signal"
        let spectralElapsed = now - lastSpectralDispatchTime
        if spectralElapsed > 66_000_000 {  // ~66ms = ~15 Hz (matches RMS)
            lastSpectralDispatchTime = now
            let muted = self.isMuted
            let snap = spectralProcessor.magnitudeSnapshot
            let centroid = muted ? Float(0.5) : spectralProcessor.spectralCentroid
            let flatness = muted ? Float(0.5) : spectralProcessor.spectralFlatness
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !snap.isEmpty { self.spectralBins = snap }
                self.spectralCentroidNormalized = centroid
                self.spectralFlatnessNormalized = flatness
            }
        }
    }

    // MARK: - Per-Lane Recording Control (?5)

    /// Toggle per-lane recording on/off.
    func toggleLaneRecording() {
        if isLaneRecording {
            stopLaneRecording()
        } else {
            startLaneRecording()
        }
    }

    private func startLaneRecording() {
        guard let format = processingFormat else { return }
        do {
            _ = try laneRecorder.startRecording(name: name, format: format)
            isLaneRecording = true
        } catch {
            print(">> Lane[\(name)] Recording failed -- \(error.localizedDescription)")
        }
    }

    private func stopLaneRecording() {
        if let url = laneRecorder.stopRecording() {
            isLaneRecording = false
            // Export metadata sidecar with lane-specific state
            AudioRecorder.exportMetadata(
                recordingURL: url,
                iterationCount: iterationCount,
                laneName: name,
                parameters: [
                    "guidanceScale": guidanceScale,
                    "shift": shift,
                    "inferMethod": inferMethod,
                    "entropyLevel": entropyLevel,
                    "granularity": granularity,
                    "feedbackAmount": feedbackAmount,
                    "excitationMode": excitationMode.rawValue,
                    "delayTime": delayTime,
                    "delayFeedback": delayFeedback,
                    "bitCrushDepth": bitCrushDepth,
                    "resonatorNote": resonatorNote,
                    "resonatorDecay": resonatorDecay
                ]
            )
        }
    }

    // MARK: - Inference Loop Control

    func startInferenceLoop() {
        guard inferenceTask == nil else { return }
        isRunning = true
        consecutiveFailures = 0
        autoDecayOrigin = inputStrength

        inferenceTask = Task(priority: .low) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.runInferenceCycle()
                // Yield to let the audio thread breathe -- inference is heavy on CPU
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
    }

    func stopInferenceLoop() {
        inferenceTask?.cancel()
        inferenceTask = nil
        isRunning = false
    }

    /// Reset all recursive state for a clean restart.
    func resetState() {
        iterationCount = 0
        isInferring = false
        consecutiveFailures = 0
        captureBuffer.reset()
        feedbackBuffer.reset()
        spectralProcessor.reset()
        signalGenerator.reset()
        delayLineBuffer = [Float](repeating: 0, count: LRConstants.maxDelaySamples)
        delayWritePos = 0
        loopSampleCount = 0
        loopReadPos = 0
        iterationArchive.removeAll(keepingCapacity: true)
        archiveRecallIndex = nil
        featureLog.removeAll(keepingCapacity: true)
    }

    /// Reconfigure this lane with a new preset without replacing the audio nodes.
    /// Used by the H19 pre-allocation strategy: nodes stay attached to the graph,
    /// only parameters change.
    func reconfigure(with preset: LanePreset) {
        resetState()
        name = preset.name
        guidanceScale = preset.guidanceScale
        shift = preset.shift
        inputStrength = preset.inputStrength
        entropyLevel = preset.entropyLevel
        granularity = preset.granularity
        inferMethod = preset.inferMethod
        inferenceSteps = preset.inferenceSteps
        feedbackAmount = preset.feedbackAmount
        autoDecayTarget = preset.autoDecayTarget
        autoDecayIterations = preset.autoDecayIterations
        autoDecayEnabled = false
        promptText = preset.prompt
        excitationMode = preset.excitationMode
        delayTime = preset.delayTime
        delayFeedback = preset.delayFeedback
        delayMix = preset.delayMix
        bitCrushDepth = preset.bitCrushDepth
        resonatorNote = preset.resonatorNote
        resonatorDecay = preset.resonatorDecay
        filterCutoff = preset.filterCutoff
        filterResonance = preset.filterResonance
        filterMode = preset.filterMode
        saturationMode = preset.saturationMode
        pulseWidth = preset.pulseWidth
        texture = preset.texture
        chaos = preset.chaos
        warmth = preset.warmth
        promptPhases = [preset.promptPhase1, preset.promptPhase2, preset.promptPhase3]
        spectralProcessor.reconfigure(fftSize: preset.fftSize)
        spectralProcessor.updateProfile(from: preset.prompt)
    }

    // MARK: - Scene Snapshot (Motherbase)

    /// Capture current performable state into a LaneSnapshot for scene store/recall.
    func makeSnapshot() -> LaneSnapshot {
        let phase = promptPhaseOverride ?? currentPromptPhase
        return LaneSnapshot(
            volume: volume,
            isMuted: isMuted,
            isSoloed: isSoloed,
            texture: texture,
            chaos: chaos,
            warmth: warmth,
            guidanceScale: guidanceScale,
            feedbackAmount: feedbackAmount,
            inputStrength: inputStrength,
            promptPhaseIndex: phase,
            excitationModeRaw: excitationMode.rawValue,
            entropyLevel: entropyLevel,
            granularity: granularity,
            delayTime: delayTime,
            delayFeedback: delayFeedback,
            delayMix: delayMix,
            bitCrushDepth: bitCrushDepth,
            resonatorNote: resonatorNote,
            resonatorDecay: resonatorDecay,
            filterCutoff: filterCutoff,
            filterResonance: filterResonance,
            filterModeRaw: filterMode.rawValue,
            saturationModeRaw: saturationMode.rawValue,
            spectralFreezeActive: spectralFreezeActive,
            denoiseStrength: denoiseStrengthDefault,
            autoDecayEnabled: autoDecayEnabled,
            feedbackSourceLaneIndex: nil,  // Resolved by NeuralEngine during scene save
            archiveRecallIndex: archiveRecallIndex,
            saturationMorph: saturationMorph
        )
    }

    /// Apply a LaneSnapshot (scene recall). Sets macros first so derived params are updated, then restores exact values from snapshot.
    func applySnapshot(_ s: LaneSnapshot) {
        volume = s.volume
        isMuted = s.isMuted
        isSoloed = s.isSoloed
        texture = s.texture
        chaos = s.chaos
        warmth = s.warmth
        guidanceScale = s.guidanceScale
        feedbackAmount = s.feedbackAmount
        inputStrength = s.inputStrength
        promptPhaseOverride = s.promptPhaseIndex
        if let mode = ExcitationMode(rawValue: s.excitationModeRaw) {
            excitationMode = mode
        }
        entropyLevel = s.entropyLevel
        granularity = s.granularity
        delayTime = s.delayTime
        delayFeedback = s.delayFeedback
        delayMix = s.delayMix
        bitCrushDepth = s.bitCrushDepth
        resonatorNote = s.resonatorNote
        resonatorDecay = s.resonatorDecay
        filterCutoff = s.filterCutoff
        filterResonance = s.filterResonance
        if let mode = FilterMode(rawValue: s.filterModeRaw) {
            filterMode = mode
        }
        if let mode = SaturationMode(rawValue: s.saturationModeRaw) {
            saturationMode = mode
        }
        spectralFreezeActive = s.spectralFreezeActive
        let d = min(max(s.denoiseStrength ?? 1.0, 0), 1)
        denoiseStrengthDefault = d
        denoiseStrengthForInference = d
        autoDecayEnabled = s.autoDecayEnabled ?? false
        archiveRecallIndex = s.archiveRecallIndex
        saturationMorph = s.saturationMorph ?? 0.0
        spectralProcessor.updateProfile(from: resolveActivePrompt())
    }

    // MARK: - Inference Cycle (Section 3.3 Recursive Formula)

    /// Execute one complete inference cycle for this lane.
    ///
    /// S_{i+1} = ACE(S_i + N(u, sigma^2), P, theta)
    ///
    /// Inference path (slow, async):
    ///   parameter snapshot -> S_i -> entropy injection ->
    ///   ACE-Step / CoreML / passthrough -> feedbackBuffer
    ///
    /// Real-time DSP (SpectralProcessor + Delay) is handled in the
    /// combinedSourceNode render callback, NOT here. This separation
    /// gives the player immediate tactile feedback from DSP controls
    /// while the AI model evolves the timbre in the background.
    ///
    /// Thread safety: All @Published reads go through snapshotParameters()
    /// which hops to the MainActor. The bridge call uses direct async/await
    /// instead of the deadlock-prone DispatchSemaphore + Task pattern.

    private func runInferenceCycle() async {
        let needed = LRConstants.bufferSize
        let avail = captureBuffer.availableToRead
        guard avail >= needed else { return }

        // 1. Read captured audio
        var inputSamples = captureBuffer.read(count: needed)

        // 1b. Trigless step: DSP-only (no ACE). Pass through and advance.
        if dspOnlyForNextCycle {
            dspOnlyForNextCycle = false
            feedbackBuffer.write(inputSamples)
            let copyCount = min(inputSamples.count, loopCapacity)
            inputSamples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                loopBuffer.update(from: base, count: copyCount)
            }
            loopSampleCount = copyCount
            await MainActor.run { [weak self] in
                self?.iterationCount += 1
                self?.isInferring = false
            }
            return
        }

        // 2. Signal inference in progress to the UI
        await MainActor.run { [weak self] in self?.isInferring = true }

        // 2b. Thread-safe parameter snapshot (all @Published reads on MainActor)
        let params = await snapshotParameters()

        // 3. Update spectral profile from resolved prompt (?4.2.2 evolution)
        spectralProcessor.updateProfile(from: params.prompt)

        // 4. Inject entropy -- per-iteration random noise (?4.2.2)
        //    Scale 0.5 gives audible stochastic variation at moderate entropy.
        //    (Was 0.1 -- too weak, resulting in near-inaudible noise injection.)
        let noiseScale = params.entropy * 0.5
        if noiseScale > 0.0001 {
            for i in 0..<inputSamples.count {
                inputSamples[i] += SignalGenerator.boxMullerNoise() * noiseScale
            }
        }

        // 5. LFO modulation (?5.2 Stochastic Parameter Evolution)
        //    Only inference-time targets (cfg, entropy, granularity) are modulated
        //    here. Real-time targets (feedback, resonator) are modulated per-buffer
        //    in the audio render callback for instant response.
        var cfg = params.cfg
        var entropy = params.entropy
        var grain = params.grain
        _ = params.feedback

        let lfoVal = signalGenerator.lfoTick(
            rate: params.lfoRate,
            samplesElapsed: needed,
            sampleRate: LRConstants.sampleRate
        )
        let modulationAmount = lfoVal * params.lfoDepth
        var unusedFb: Float = 0.0
        var unusedPitch: Float = 0.0
        applyLFOModulation(
            value: modulationAmount, target: params.lfoTarget,
            cfg: &cfg, entropy: &entropy, grain: &grain,
            feedback: &unusedFb, resPitch: &unusedPitch
        )

        // 6. Process through priority chain:
        //    (a) ACE-Step Bridge -> (b) Core ML -> (c) passthrough
        //
        //    NOTE: SpectralProcessor + Delay Line are now in the REAL-TIME
        //    audio path (setupFeedbackSourceNode render callback), NOT here.
        //    This keeps DSP controls responsive (<5ms) while inference runs
        //    asynchronously (2-30s per cycle).
        var processedSamples: [Float] = []
        // --- (a) ACE-Step Bridge (with circuit breaker) ---
        // Skip ACE when denoise strength is 0 (per-step lock or DSP-only).
        if consecutiveFailures < LRConstants.maxConsecutiveFailures,
           params.denoiseStrength > 0.0001,
           let bridge = bridge {
            let bridgeStatus = bridge.status
            if bridgeStatus == .connected || bridgeStatus == .modelLoaded {
                do {
                    let result = try await bridge.infer(
                        samples: inputSamples,
                        prompt: params.prompt,
                        guidanceScale: cfg,
                        numSteps: params.steps,
                        seed: -1,
                        inputStrength: params.strength,
                        entropy: entropy,
                        granularity: grain,
                        taskType: LRConstants.aceTaskTypeDefault,
                        thinking: LRConstants.aceThinkingDefault,
                        shift: params.shift,
                        inferMethod: params.inferMethod,
                        denoiseStrength: params.denoiseStrength
                    )
                    if !result.isEmpty {
                        processedSamples = result
                        consecutiveFailures = 0
                    }
                } catch {
                    print(">> Lane[\(params.name)] Bridge inference failed: \(error.localizedDescription)")
                    consecutiveFailures += 1
                    if consecutiveFailures >= LRConstants.maxConsecutiveFailures {
                        print(">> Lane[\(params.name)] Circuit breaker OPEN -- backing off \(LRConstants.inferenceBackoffSeconds)s")
                        try? await Task.sleep(nanoseconds: UInt64(LRConstants.inferenceBackoffSeconds * 1_000_000_000))
                        consecutiveFailures = 0
                        print(">> Lane[\(params.name)] Circuit breaker CLOSED -- resuming")
                    }
                }
            }
        }

        // --- (b) Core ML On-Device Pipeline ---
        if processedSamples.isEmpty,
           let inference = coreMLInference, inference.isModelLoaded {
            processedSamples = inference.processPipeline(
                inputSamples: inputSamples,
                guidanceScale: cfg,
                entropyLevel: entropy,
                granularity: grain,
                inputStrength: params.strength,
                prompt: params.prompt
            )
        }

        // --- (c) Passthrough -- feed raw captured audio back into the loop.
        //     The real-time SpectralProcessor in the audio render callback
        //     will process this, creating the recursive degradation effect
        //     even without a neural backend (pure DSP feedback loop).
        if processedSamples.isEmpty {
            processedSamples = inputSamples
        }

        // 7. Write to feedback ring buffer (DSP happens in real-time path)
        feedbackBuffer.write(processedSamples)

        // 7b. Copy to loop buffer for sustain between inference cycles.
        //     When the ring buffer drains (~1s), the render callback reads
        //     from this loop, keeping the feedback path continuously fed
        //     with AI-generated material until the next inference cycle.
        let copyCount = min(processedSamples.count, loopCapacity)
        processedSamples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            loopBuffer.update(from: base, count: copyCount)
        }
        loopSampleCount = copyCount

        // 7c. Append to iteration archive (ring buffer, capped at iterationArchiveSize)
        iterationArchive.append(processedSamples)
        if iterationArchive.count > LRConstants.iterationArchiveSize {
            iterationArchive.removeFirst()
        }

        // 8. Increment iteration counter, update spectral features, apply auto-decay, clear inference flag
        let centroid = spectralProcessor.spectralCentroid
        let flatness = spectralProcessor.spectralFlatness
        let flux = spectralProcessor.spectralFlux
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            self.iterationCount += 1
            self.isInferring = false

            // Publish spectral features for UI and prompt evolution
            self.spectralCentroidNormalized = centroid
            self.spectralFlatnessNormalized = flatness

            // Append spectral feature snapshot to telemetry log
            let snapshot = SpectralFeatureSnapshot(
                iteration: self.iterationCount,
                centroid: centroid,
                flatness: flatness,
                flux: flux,
                promptPhase: self.currentPromptPhase,
                inputStrength: self.inputStrength,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
            self.featureLog.append(snapshot)
            if self.featureLog.count > LRConstants.featureLogMaxEntries {
                self.featureLog.removeFirst()
            }

            // Auto-decay: interpolate inputStrength toward preset target (?4.2.2)
            if self.autoDecayEnabled, self.autoDecayIterations > 0 {
                let progress = min(Float(self.iterationCount) / self.autoDecayIterations, 1.0)
                self.inputStrength = self.autoDecayOrigin
                    + (self.autoDecayTarget - self.autoDecayOrigin) * progress
            }
        }
    }

    // MARK: - Thread-Safe Parameter Snapshot

    /// Capture all @Published parameter values on the MainActor.
    ///
    /// This prevents torn reads when the inference loop (background Task)
    /// accesses parameters that the UI (main thread) may be modifying.
    /// Returns nil if the lane has been deallocated.
    @MainActor
    private func snapshotParameters() -> CycleParameters {
        CycleParameters(
            name: self.name,
            cfg: self.guidanceScale,
            entropy: self.entropyLevel / 100.0,
            grain: self.granularity / 100.0,
            strength: self.inputStrength,
            feedback: self.feedbackAmount,
            freeze: self.spectralFreezeActive,
            crush: self.bitCrushDepth,
            resonatorNote: self.resonatorNote,
            shift: self.shift,
            inferMethod: self.inferMethod,
            steps: self.inferenceSteps,
            prompt: self.resolveActivePrompt(),
            lfoRate: self.lfoRate,
            lfoDepth: self.lfoDepth,
            lfoTarget: self.lfoTarget,
            denoiseStrength: self.denoiseStrengthForInference
        )
    }

    // MARK: - LFO Modulation (?5.2)

    private func applyLFOModulation(
        value: Float, target: LFOTarget,
        cfg: inout Float, entropy: inout Float, grain: inout Float,
        feedback: inout Float, resPitch: inout Float
    ) {
        switch target {
        case .none:       break
        case .entropy:    entropy = clamp(entropy + value * 0.5, min: 0.0, max: 1.0)
        case .granularity: grain = clamp(grain + value * 0.5, min: 0.0, max: 1.0)
        case .guidance:
            let range = LRConstants.cfgScaleRange
            cfg = clamp(cfg + value * 3.0, min: range.lowerBound, max: range.upperBound)
        case .feedback:   feedback = clamp(feedback + value * 0.3, min: 0.0, max: 1.0)
        case .resonator:
            let range = LRConstants.resonatorPitchRange
            resPitch = clamp(resPitch + value * 200.0, min: range.lowerBound, max: range.upperBound)
        }
    }

    // MARK: - Delay Line (The Lucier Chamber -- ?1.2)

    /// Internal for @testable access in knob-check tests.
    func applyDelayLine(_ samples: inout [Float]) {
        let delayTimeSec = delayTime
        let delayFb = delayFeedback
        let mix = delayMix
        guard delayTimeSec > 0.001, mix > 0.001 else { return }

        let delaySamples = min(
            Int(Double(delayTimeSec) * LRConstants.sampleRate),
            LRConstants.maxDelaySamples - 1
        )
        guard delaySamples > 0 else { return }

        for i in 0..<samples.count {
            let readPos = (delayWritePos - delaySamples + LRConstants.maxDelaySamples)
                          % LRConstants.maxDelaySamples
            let delayed = delayLineBuffer[readPos]
            let wet = delayed.isNaN || delayed.isInfinite ? 0 : delayed
            let dry = samples[i].isNaN || samples[i].isInfinite ? 0 : samples[i]
            let writeVal = dry + wet * delayFb
            delayLineBuffer[delayWritePos] = writeVal.isNaN || writeVal.isInfinite ? 0 : writeVal
            delayWritePos = (delayWritePos + 1) % LRConstants.maxDelaySamples
            samples[i] = dry * (1.0 - mix) + wet * mix
        }
    }

    // MARK: - Prompt Evolution (?4.2.2 -- Per-Lane Recursive Drift)

    /// Resolve the active prompt for this lane's current iteration phase.
    ///
    /// Each lane has its own 3-phase prompt evolution chain (stored in
    /// `promptPhases` from the `LanePreset`), enabling distinct timbral
    /// trajectories: DRUMS stays rhythmic, BASS stays sub-harmonic,
    /// SYNTH stays spectral, NOISE stays entropic.
    ///
    /// When prompt evolution is disabled, returns the manual `promptText`.
    /// When promptPhaseOverride is set (performance step lock), uses that phase instead of currentPromptPhase.
    private func resolveActivePrompt() -> String {
        guard promptEvolutionEnabled else { return promptText }
        let phase = promptPhaseOverride ?? currentPromptPhase
        let phaseIndex = min(phase - 1, promptPhases.count - 1)
        return promptPhases[max(0, phaseIndex)]
    }

    // MARK: - Macro Control Engine (Curated Multi-Parameter Gestures)
    //
    // Three macros that move multiple parameters simultaneously along
    // curated curves, implementing perceptual parameter grouping based
    // on auditory scene analysis (Bregman, 1990) and gestural control
    // principles from motor learning research in musical performance.
    // The macro sets a musical starting point; individual parameters
    // can still be tweaked afterward (macro -> detail).
    //
    // All interpolation uses linear lerp between defined breakpoints.
    // This keeps the mapping predictable and debuggable.
    //
    // Batched updates: each macro pre-computes all values, then assigns
    // properties within a single DispatchQueue.main.async block. SwiftUI's
    // RunLoop coalesces multiple objectWillChange.send() calls within the
    // same execution context into a single view body re-evaluation.

    /// TEXTURE (0->1): clean/pure -> complex/rich.
    /// Controls filter cutoff, entropy, granularity, bit crush, and saturation.
    /// Internal for @testable knob-check tests.
    func applyMacroTexture() {
        let t = texture
        // Pre-compute all derived values
        let newCutoff = expLerp(20000.0, 2000.0, 200.0, t)
        let newEntropy = lerp3(0.0, 20.0, 50.0, t)
        let newGrain = lerp3(0.0, 15.0, 40.0, t)
        let newCrush = lerp3(16.0, 10.0, 6.0, t)
        let newSat: SaturationMode = t < 0.33 ? .clean : (t < 0.66 ? .tube : .transistor)
        // Single notification + batch assignment
        objectWillChange.send()
        filterCutoff = newCutoff
        entropyLevel = newEntropy
        granularity = newGrain
        bitCrushDepth = newCrush
        saturationMode = newSat
    }

    /// CHAOS (0->1): AI stays close -> AI runs wild.
    /// Controls inputStrength, guidanceScale, and inferMethod.
    /// Internal for @testable knob-check tests.
    func applyMacroChaos() {
        let c = chaos
        let newStrength = lerp3(0.8, 0.5, 0.2, c)
        let newCfg = lerp3(5.0, 12.0, 18.0, c)
        let newMethod = c < 0.7 ? "ode" : "sde"
        objectWillChange.send()
        inputStrength = newStrength
        guidanceScale = newCfg
        inferMethod = newMethod
    }

    /// WARMTH (0->1): cold digital -> warm analog.
    /// Controls saturation, filter resonance, resonator, and delay.
    /// Internal for @testable knob-check tests.
    func applyMacroWarmth() {
        let w = warmth
        // Continuous saturation morphing: each mode occupies a 1/3 band of warmth.
        // Within each band, saturationMorph crossfades toward the next mode.
        let newSat: SaturationMode
        let morph: Float
        if w < 0.33 {
            newSat = .clean
            morph = w / 0.33             // 0 at w=0, 1 at w=0.33
        } else if w < 0.66 {
            newSat = .tube
            morph = (w - 0.33) / 0.33    // 0 at w=0.33, 1 at w=0.66
        } else {
            newSat = .transistor
            morph = (w - 0.66) / 0.34    // 0 at w=0.66, 1 at w=1.0
        }
        let newRes = lerp3(0.0, 0.3, 0.6, w)
        let newDecay = lerp3(0.3, 0.6, 0.85, w)
        let newMix = lerp3(0.0, 0.2, 0.4, w)
        objectWillChange.send()
        saturationMode = newSat
        saturationMorph = min(morph, 1.0)
        filterResonance = newRes
        resonatorDecay = newDecay
        delayMix = newMix
    }

    /// 3-point linear interpolation: t=0->a, t=0.5->b, t=1->c
    @inline(__always)
    private func lerp3(_ a: Float, _ b: Float, _ c: Float, _ t: Float) -> Float {
        if t <= 0.5 {
            let n = t * 2.0  // 0..1 within first half
            return a + (b - a) * n
        } else {
            let n = (t - 0.5) * 2.0  // 0..1 within second half
            return b + (c - b) * n
        }
    }

    /// Exponential-feeling 3-point interpolation for frequency values.
    /// Lerps in log domain for perceptually linear cutoff sweeps.
    @inline(__always)
    private func expLerp(_ a: Float, _ b: Float, _ c: Float, _ t: Float) -> Float {
        let logA = log2f(max(a, 1.0))
        let logB = log2f(max(b, 1.0))
        let logC = log2f(max(c, 1.0))
        let logResult = lerp3(logA, logB, logC, t)
        return powf(2.0, logResult)
    }

    // MARK: - Helpers

    private func clamp(_ value: Float, min lo: Float, max hi: Float) -> Float {
        return Swift.min(Swift.max(value, lo), hi)
    }
}
